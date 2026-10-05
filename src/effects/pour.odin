package effects

import "../engine"
import "core:math/ease"
import "core:slice"

import "core:fmt"

// pour — characters pour in from one edge, group by group. Groups live in one
// flat pool; the group being poured is a span into it.

Pour_Direction :: enum {
	Up,
	Down,
	Left,
	Right,
}

Pour_Config :: struct {
	pour_direction:           Pour_Direction,
	pour_speed:               int,
	movement_speed_range:     Float_Range_Value,
	gap:                      int,
	starting_color:           engine.Color,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_frames:    int,
	final_gradient_direction: engine.Gradient_Direction,
	movement_easing:          ease.Ease,
}

pour_config_default :: proc() -> Pour_Config {
	cfg := Pour_Config {
		pour_direction           = .Down,
		pour_speed               = 2,
		movement_speed_range     = {0.4, 0.6},
		gap                      = 1,
		starting_color           = engine.Color{0xff, 0xff, 0xff},
		final_gradient_frames    = 6,
		final_gradient_direction = .Vertical,
		movement_easing          = .Quadratic_In,
	}
	append(
		&cfg.final_gradient_stops,
		..[]engine.Color {
			engine.Color{0x8A, 0x00, 0x8A},
			engine.Color{0x00, 0xD1, 0xFF},
			engine.Color{0xFF, 0xFF, 0xFF},
		},
	)
	append(&cfg.final_gradient_steps, 12)
	return cfg
}

pour_parse :: proc(cfg: ^Pour_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--pour-direction":
			v, ok := opt_value(args, &i, value, has_value)
			if !ok do return false
			switch v {
			case "up":
				cfg.pour_direction = .Up
			case "down":
				cfg.pour_direction = .Down
			case "left":
				cfg.pour_direction = .Left
			case "right":
				cfg.pour_direction = .Right
			case:
				return false
			}
		case "--pour-speed":
			if !parse_int_flag(&cfg.pour_speed, args, &i, value, has_value) do return false
		case "--movement-speed-range":
			if !parse_float_range_flag(&cfg.movement_speed_range, args, &i, value, has_value) do return false
		case "--gap":
			if !parse_int_flag(&cfg.gap, args, &i, value, has_value, minimum = 0) do return false
		case "--starting-color":
			if !parse_color_flag(&cfg.starting_color, args, &i, value, has_value) do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-frames":
			if !parse_int_flag(&cfg.final_gradient_frames, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case "--movement-easing":
			if !parse_ease_flag(&cfg.movement_easing, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown pour option: ", name)
			return false
		}
	}
	return true
}

Pour_State :: struct {
	config:         Pour_Config,
	pool:           [dynamic]engine.Particle_Id, // all groups, concatenated
	group_spans:    [dynamic]engine.Span, // one span per group
	index_by_id:    [dynamic]int,
	fades:          engine.Appearance_Ramp,
	fade_index:     [dynamic]int,
	color_ticks:    [dynamic]int,
	origins:        [dynamic]engine.Coord,
	targets:        [dynamic]engine.Coord,
	max_steps:      [dynamic]int,
	start_ticks:    [dynamic]int,
	active_slots:   [dynamic]int,
	color_steps:    int,
	group_idx:      int, // group currently being poured
	head:           int, // cursor within the current group
	gap:            int,
	tick:           int,
	color_handling: engine.Existing_Color_Handling,
}

pour_build :: proc(s: ^Pour_State, e: ^engine.Engine) {
	spectrum := engine.gradient_make(
		s.config.final_gradient_stops[:],
		s.config.final_gradient_steps[:],
		false,
		context.temp_allocator,
	)
	defer delete(spectrum)
	sampler := engine.gradient_sampler(
		e.canvas.text_bottom,
		e.canvas.text_top,
		e.canvas.text_left,
		e.canvas.text_right,
		s.config.final_gradient_direction,
	)

	grouping: engine.Particle_Group
	switch s.config.pour_direction {
	case .Down:
		grouping = .Row_B2T
	case .Up:
		grouping = .Row_T2B
	case .Left:
		grouping = .Column_L2R
	case .Right:
		grouping = .Column_R2L
	}
	query := engine.Particle_Query {
		e.particle_sets,
		e.particles.initial_coord[:len(e.particles)],
		e.canvas,
	}
	groups := engine.get_particles_grouped(query, engine.PARTICLE_FILTER_INPUT, grouping)
	defer engine.groups_delete(&groups)
	n := len(e.particle_sets.input)
	reserve(&s.pool, n)
	reserve(&s.group_spans, len(groups.spans))
	reserve(&s.active_slots, n)
	s.color_handling = e.cfg.existing_color_handling
	s.index_by_id = make([dynamic]int, len(e.particles))
	s.color_ticks = make([dynamic]int, n)
	s.origins = make([dynamic]engine.Coord, n)
	s.targets = make([dynamic]engine.Coord, n)
	s.max_steps = make([dynamic]int, n)
	s.start_ticks = make([dynamic]int, n)
	s.color_steps = s.color_handling == .Dynamic ? 10 : s.config.final_gradient_steps[0]
	for i in 0 ..< n do s.start_ticks[i] = -1
	if n == 0 do return

	fade_tweens := make([]engine.Tween(engine.Appearance), n, context.temp_allocator)
	defer delete(fade_tweens, context.temp_allocator)
	starting := s.config.starting_color
	full_color_ticks := (s.color_steps + 1) * s.config.final_gradient_frames

	initial_coords := e.particles.initial_coord[:len(e.particles)]
	current_coords := e.particles.current_coord[:]
	visible_flags := e.particles.flags[:]

	for gi in 0 ..< len(groups.spans) {
		g := engine.group_members(groups, gi)
		if gi % 2 == 1 do slice.reverse(g) // pour direction alternates
		append(&s.group_spans, engine.Span{start = len(s.pool), len = len(g)})
		for id in g {
			slot := len(s.pool)
			append(&s.pool, id)
			s.index_by_id[id] = slot
			c := initial_coords[id]
			start: engine.Coord
			switch s.config.pour_direction {
			case .Down:
				start = engine.coord(c.column, e.canvas.top)
			case .Up:
				start = engine.coord(c.column, e.canvas.bottom)
			case .Left:
				start = engine.coord(e.canvas.right, c.row)
			case .Right:
				start = engine.coord(e.canvas.left, c.row)
			}
			current_coords[id] = start
			s.origins[slot] = start
			s.targets[slot] = c
			if s.color_handling == .Dynamic {
				style := engine.get_initial_appearance(e, id)
				s.color_ticks[slot] =
					style.colors.fg == nil && style.colors.bg == nil ? s.config.final_gradient_frames : full_color_ticks
				fade_tweens[slot] = {
					from = {colors = {starting, starting}},
					to   = {colors = style.colors},
				}
			} else {
				s.color_ticks[slot] = full_color_ticks
				final_color := engine.gradient_sample(sampler, spectrum[:], c)
				fade_tweens[slot] = {
					from = {colors = {fg = starting}},
					to   = {colors = {fg = final_color}},
				}
			}
			speed := engine.random_float_range(
				s.config.movement_speed_range.lo,
				s.config.movement_speed_range.hi,
			)
			s.max_steps[slot] = max(
				engine.round_to_int(engine.line_length(start, c, true) / speed),
				1,
			)
			visible_flags[id] -= {.Visible}
		}
	}
	unique_tweens: [dynamic]engine.Tween(engine.Appearance)
	unique_tweens, s.fade_index = engine.group_values(fade_tweens)
	defer delete(unique_tweens)
	s.fades = engine.ramp_make(e, unique_tweens[:], s.color_steps)
}

pour_next :: proc(s: ^Pour_State, e: ^engine.Engine) -> bool #no_bounds_check {
	spans := s.group_spans[:]
	pool := s.pool[:]
	if s.group_idx >= len(spans) && len(s.active_slots) == 0 {
		return false
	}
	if s.group_idx < len(spans) {
		cur := spans[s.group_idx]
		if s.gap == 0 {
			for _ in 0 ..< s.config.pour_speed {
				if s.head >= cur.len do break
				next := pool[cur.start + s.head]
				s.head += 1
				engine.set_visible(e, next, true)
				slot := s.index_by_id[next]
				s.start_ticks[slot] = s.tick
				append(&s.active_slots, slot)
			}
			if s.head >= cur.len {
				s.group_idx += 1
				s.head = 0
			}
			s.gap = s.config.gap
		} else {
			s.gap -= 1
		}
	}
	frames := s.config.final_gradient_frames
	color_steps := s.color_steps
	write := 0
	for slot in s.active_slots {
		id := pool[slot]
		age := s.tick - s.start_ticks[slot]
		max_step := s.max_steps[slot]
		c_ticks := s.color_ticks[slot]
		life := max(max_step, c_ticks)
		if age >= life do continue
		if age < max_step {
			progress := f64(age + 1) / f64(max_step)
			engine.set_position(
				e,
				id,
				engine.tween(
					s.origins[slot],
					s.targets[slot],
					ease.ease(s.config.movement_easing, progress),
				),
			)
		} else if age == max_step {
			engine.set_position(e, id, s.targets[slot])
		}
		if age < c_ticks {
			if age % frames == 0 {
				step := min(age / frames, color_steps)
				engine.set_appearance(e, id, engine.ramp_code(s.fades, s.fade_index[slot], step))
			}
		} else if age == c_ticks {
			engine.set_appearance(e, id, engine.ramp_code(s.fades, s.fade_index[slot], color_steps))
		}
		if age + 1 < life {
			s.active_slots[write] = slot
			write += 1
		}
	}
	resize(&s.active_slots, write)
	s.tick += 1
	return true
}
