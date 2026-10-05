package effects

import "../engine"

import "core:fmt"
import "core:math/ease"

Bubbles_Pop_Condition :: enum {
	Row,
	Bottom,
	Anywhere,
}

Bubbles_Bubble_State :: enum u8 {
	Pending,
	Float,
	Pop,
	Done,
}

bubbles_pop_condition_parse :: proc(s: string) -> (Bubbles_Pop_Condition, bool) {
	switch s {
	case "row":
		return .Row, true
	case "bottom":
		return .Bottom, true
	case "anywhere":
		return .Anywhere, true
	}
	return .Row, false
}

Bubbles_Config :: struct {
	rainbow:                  bool,
	bubble_colors:            [dynamic]engine.Color,
	pop_color:                engine.Color,
	bubble_speed:             f64,
	bubble_delay:             int,
	pop_condition:            Bubbles_Pop_Condition,
	movement_easing:          ease.Ease,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

bubbles_config_default :: proc() -> Bubbles_Config {
	cfg := Bubbles_Config {
		pop_color                = engine.Color{0xFF, 0xFF, 0xFF},
		bubble_speed             = 0.5,
		bubble_delay             = 20,
		movement_easing          = .Sine_In_Out,
		final_gradient_direction = .Diagonal,
	}
	append(
		&cfg.bubble_colors,
		..[]engine.Color {
			engine.Color{0xD3, 0x3A, 0xFF},
			engine.Color{0x73, 0x95, 0xC4},
			engine.Color{0x43, 0xC2, 0xA7},
			engine.Color{0x02, 0xFF, 0x7F},
		},
	)
	append(
		&cfg.final_gradient_stops,
		engine.Color{0xD3, 0x3A, 0xFF},
		engine.Color{0x02, 0xFF, 0x7F},
	)
	append(&cfg.final_gradient_steps, 12)
	return cfg
}

bubbles_parse :: proc(cfg: ^Bubbles_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--rainbow":
			if !parse_bool_flag(&cfg.rainbow, has_value) do return false
		case "--bubble-colors":
			if !parse_colors_flag(&cfg.bubble_colors, args, &i, value, has_value) do return false
		case "--pop-color":
			if !parse_color_flag(&cfg.pop_color, args, &i, value, has_value) do return false
		case "--bubble-speed":
			if !parse_float_flag(&cfg.bubble_speed, args, &i, value, has_value) || cfg.bubble_speed <= 0 do return false
		case "--bubble-delay":
			if !parse_int_flag(&cfg.bubble_delay, args, &i, value, has_value) || cfg.bubble_delay <= 0 do return false
		case "--pop-condition":
			v, ok := opt_value(args, &i, value, has_value)
			if !ok do return false
			condition, valid := bubbles_pop_condition_parse(v)
			if !valid do return false
			cfg.pop_condition = condition
		case "--movement-easing":
			if !parse_ease_flag(&cfg.movement_easing, args, &i, value, has_value) do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown bubbles option: ", name)
			return false
		}
	}
	return true
}

Bubbles_State :: struct {
	config:             Bubbles_Config,
	characters:         [dynamic]engine.Particle_Id,
	final_index:        [dynamic]int, // Particle_Id indexed ramp row
	fades:              engine.Appearance_Ramp,
	uncolored_dynamic:  [dynamic]bool, // Particle_Id indexed
	circle_dx:          [dynamic]int, // Particle_Id indexed
	circle_dy:          [dynamic]int,
	color_offsets:      [dynamic]int,
	pop_offsets:        [dynamic]engine.Coord,
	pop_origins:        [dynamic]engine.Coord,
	pop_targets:        [dynamic]engine.Coord,
	expand_steps:       [dynamic]int,
	pop_steps:          [dynamic]int,
	bubbles:            engine.Particle_Groups,
	bubble_origins:     [dynamic]engine.Coord,
	bubble_targets:     [dynamic]engine.Coord,
	last_anchors:       [dynamic]engine.Coord,
	bubble_steps:       [dynamic]int,
	bubble_radii:       [dynamic]int,
	bubble_colors:      [dynamic]engine.Color,
	bubble_color_codes: [dynamic]engine.Appearance_Id,
	bubble_states:      [dynamic]Bubbles_Bubble_State,
	bubble_starts:      [dynamic]int,
	pop_starts:         [dynamic]int,
	active_bubbles:     [dynamic]int,
	next_bubble:        int,
	delay:              int,
	rainbow_palette:    [dynamic]engine.Color,
	rainbow_codes:      [dynamic]engine.Appearance_Id,
	pop_code:           engine.Appearance_Id,
	tick:               int,
	color_handling:     engine.Existing_Color_Handling,
}

bubbles_build :: proc(s: ^Bubbles_State, e: ^engine.Engine) {
	s.color_handling = e.cfg.existing_color_handling
	final_spectrum := engine.gradient_make(
		s.config.final_gradient_stops[:],
		s.config.final_gradient_steps[:],
		false,
		context.temp_allocator,
	)
	defer delete(final_spectrum)
	final_sampler := engine.gradient_sampler(
		e.canvas.text_bottom,
		e.canvas.text_top,
		e.canvas.text_left,
		e.canvas.text_right,
		s.config.final_gradient_direction,
	)
	query := engine.Particle_Query {
		e.particle_sets,
		e.particles.initial_coord[:len(e.particles)],
		e.canvas,
	}
	s.characters = engine.get_particles(
		query,
		engine.PARTICLE_FILTER_INPUT,
		.Top_Bottom_Left_Right,
	)
	n_particles := len(e.particles)
	s.final_index = make([dynamic]int, n_particles)
	s.circle_dx = make([dynamic]int, n_particles)
	s.circle_dy = make([dynamic]int, n_particles)
	s.color_offsets = make([dynamic]int, n_particles)
	s.pop_offsets = make([dynamic]engine.Coord, n_particles)
	s.pop_origins = make([dynamic]engine.Coord, n_particles)
	s.pop_targets = make([dynamic]engine.Coord, n_particles)
	s.expand_steps = make([dynamic]int, n_particles)
	s.pop_steps = make([dynamic]int, n_particles)
	initial_coords := e.particles.initial_coord
	visible_flags := e.particles.flags

	s.pop_code = engine.prepare_appearance(e, engine.Appearance{colors = {fg = s.config.pop_color}})
	if s.color_handling == .Dynamic {
		s.uncolored_dynamic = make([dynamic]bool, n_particles)
		tweens := make([]engine.Tween(engine.Appearance), len(s.characters), context.temp_allocator)
		defer delete(tweens, context.temp_allocator)
		for id, slot in s.characters {
			init_style := engine.get_initial_appearance(e, id)
			s.uncolored_dynamic[id] = init_style.colors.fg == nil && init_style.colors.bg == nil
			tweens[slot] = {
				from = {colors = {s.config.pop_color, s.config.pop_color}, bold = init_style.bold},
				to   = {colors = init_style.colors, bold = init_style.bold},
			}
			visible_flags[id] -= {.Visible}
			e.particles.layer[id] = 1
		}
		unique_tweens, slot_rows := engine.group_values(tweens)
		defer delete(unique_tweens)
		defer delete(slot_rows)
		if len(unique_tweens) > 0 {
			s.fades = engine.ramp_make(e, unique_tweens[:], 8)
			for id, slot in s.characters do s.final_index[id] = slot_rows[slot]
		}
	} else {
		s.fades = engine.ramp_make(e, engine.tweens_from(s.config.pop_color, final_spectrum[:]), 8)
		for id in s.characters {
			s.final_index[id] = engine.gradient_sample_index(
				final_sampler,
				len(final_spectrum),
				initial_coords[id],
			)
			visible_flags[id] -= {.Visible}
			e.particles.layer[id] = 1
		}
	}

	palette_codes := make([]engine.Appearance_Id, max(len(s.config.bubble_colors), 1), context.temp_allocator)
	defer delete(palette_codes, context.temp_allocator)
	if len(s.config.bubble_colors) == 0 {
		palette_codes[0] = engine.prepare_appearance(e, engine.Appearance{})
	} else {
		for color, ci in s.config.bubble_colors {
			palette_codes[ci] = engine.prepare_appearance(e, engine.Appearance{colors = {fg = color}})
		}
	}

	rows := engine.get_particles_grouped(query, engine.PARTICLE_FILTER_INPUT, .Row_B2T)
	defer engine.groups_delete(&rows)
	read := 0
	for read < len(rows.members) {
		remaining := len(rows.members) - read
		count := remaining < 5 ? remaining : engine.random_range(5, min(remaining, 20) + 1)
		start := len(s.bubbles.members)
		append(&s.bubbles.members, ..rows.members[read:read + count])
		append(&s.bubbles.spans, engine.Span{start, count})
		read += count
	}
	bubble_count := len(s.bubbles.spans)
	s.bubble_origins = make([dynamic]engine.Coord, bubble_count)
	s.bubble_targets = make([dynamic]engine.Coord, bubble_count)
	s.last_anchors = make([dynamic]engine.Coord, bubble_count)
	s.bubble_steps = make([dynamic]int, bubble_count)
	s.bubble_radii = make([dynamic]int, bubble_count)
	s.bubble_colors = make([dynamic]engine.Color, bubble_count)
	s.bubble_color_codes = make([dynamic]engine.Appearance_Id, bubble_count)
	s.bubble_states = make([dynamic]Bubbles_Bubble_State, bubble_count)
	s.bubble_starts = make([dynamic]int, bubble_count)
	s.pop_starts = make([dynamic]int, bubble_count)
	for bi in 0 ..< bubble_count {
		members := engine.group_members(s.bubbles, bi)
		radius := max(len(members) / 5, 1)
		lowest := e.canvas.bottom
		if s.config.pop_condition == .Row {
			lowest = initial_coords[members[0]].row
			for id in members do lowest = min(lowest, initial_coords[id].row)
		}
		origin := engine.coord(
			engine.random_range(e.canvas.left, e.canvas.right + 1),
			e.canvas.top + 10,
		)
		target := engine.coord(engine.random_range(e.canvas.left, e.canvas.right + 1), lowest)
		s.bubble_origins[bi] = origin
		s.bubble_targets[bi] = target
		s.last_anchors[bi] = engine.coord(min(int), min(int))
		s.bubble_steps[bi] = max(
			engine.round_to_int(engine.line_length(origin, target, true) / s.config.bubble_speed),
			1,
		)
		s.bubble_radii[bi] = radius
		ci := engine.random_below(max(len(s.config.bubble_colors), 1))
		if len(s.config.bubble_colors) > 0 do s.bubble_colors[bi] = s.config.bubble_colors[ci]
		s.bubble_color_codes[bi] = palette_codes[ci]
		circle_points := engine.find_coords_on_circle(
			engine.coord(0, 0),
			radius,
			len(members),
			false,
			context.temp_allocator,
		)
		pop_points := engine.find_coords_on_circle(
			engine.coord(0, 0),
			radius + 3,
			len(members),
			false,
			context.temp_allocator,
		)
		palette_offset := 0
		for id, point in members {
			s.circle_dx[id] = circle_points[point].column
			s.circle_dy[id] = circle_points[point].row
			s.color_offsets[id] = palette_offset
			palette_offset += (point + 1) * 2
			s.pop_offsets[id] = pop_points[point]
			s.expand_steps[id] = max(
				engine.round_to_int(
					engine.line_length(circle_points[point], pop_points[point], true) / 0.3,
				),
				1,
			)
		}
		delete(circle_points)
		delete(pop_points)
	}
	if s.config.rainbow {
		s.rainbow_palette = engine.gradient_make(
			[]engine.Color {
				engine.Color{0xE8, 0x14, 0x16},
				engine.Color{0xFF, 0xA5, 0x00},
				engine.Color{0xFA, 0xEB, 0x36},
				engine.Color{0x79, 0xC3, 0x14},
				engine.Color{0x48, 0x7D, 0xE7},
				engine.Color{0x4B, 0x36, 0x9D},
				engine.Color{0x70, 0x36, 0x9D},
			},
			[]int{5},
			false,
		)
		s.rainbow_codes = make([dynamic]engine.Appearance_Id, len(s.rainbow_palette))
		for color, ri in s.rainbow_palette {
			s.rainbow_codes[ri] = engine.prepare_appearance(e, engine.Appearance{colors = {fg = color}})
		}
		for id in s.characters {
			for s.color_offsets[id] >= len(s.rainbow_palette) do s.color_offsets[id] -= len(s.rainbow_palette)
		}
	}
	reserve(&s.active_bubbles, len(s.bubbles.spans))
	s.delay = s.config.bubble_delay
}

bubbles_next :: proc(s: ^Bubbles_State, e: ^engine.Engine) -> bool #no_bounds_check {
	if s.next_bubble == len(s.bubbles.spans) && len(s.active_bubbles) == 0 do return false
	if s.next_bubble < len(s.bubbles.spans) {
		if s.delay == 0 {
			bi := s.next_bubble
			s.next_bubble += 1
			append(&s.active_bubbles, bi)
			s.bubble_states[bi] = .Float
			s.bubble_starts[bi] = s.tick
			s.delay = s.config.bubble_delay - 1
		} else {
			s.delay -= 1
		}
	}

	initial_coords := e.particles.initial_coord

	write := 0
	for bi in s.active_bubbles {
		state := s.bubble_states[bi]
		members := engine.group_members(s.bubbles, bi)
		if state == .Float {
			age := s.tick - s.bubble_starts[bi]
			steps := s.bubble_steps[bi]
			progress := f64(min(age + 1, steps)) / f64(steps)
			anchor := engine.tween(s.bubble_origins[bi], s.bubble_targets[bi], progress)
			moved := age == 0 || anchor != s.last_anchors[bi]
			recolor := (s.config.rainbow && age % 4 == 0) || (!s.config.rainbow && age == 0)
			landed := age + 1 >= steps
			if moved || recolor {
				s.last_anchors[bi] = anchor
				target_row := s.bubble_targets[bi].row
				rainbow_step := (age / 4) % len(s.rainbow_palette) if s.config.rainbow else 0
				for id in members {
					if moved {
						c := engine.coord(anchor.column + s.circle_dx[id], anchor.row + s.circle_dy[id])
						if age == 0 {
							engine.set_symbol(e, id, e.particles.initial_symbol[id])
							engine.set_particle(e, id, c, true, 1)
						} else {
							engine.set_position(e, id, c)
						}
						landed ||= c.row == target_row
					}
					if recolor {
						if s.config.rainbow {
							color_index := s.color_offsets[id] + rainbow_step
							if color_index >= len(s.rainbow_palette) do color_index -= len(s.rainbow_palette)
							if s.color_handling == .Dynamic {
								engine.set_foreground(e, id, s.rainbow_palette[color_index])
							} else {
								engine.set_appearance(e, id, s.rainbow_codes[color_index])
							}
						} else {
							if s.color_handling == .Dynamic {
								engine.set_foreground(e, id, s.bubble_colors[bi])
							} else {
								engine.set_appearance(e, id, s.bubble_color_codes[bi])
							}
						}
					}
				}
			}
			if landed || (s.config.pop_condition == .Anywhere && engine.random_float() < 0.002) {
				s.bubble_states[bi] = .Pop
				s.pop_starts[bi] = s.tick + 1
				for id in members {
					s.pop_origins[id] = engine.coord(
						anchor.column + s.circle_dx[id],
						anchor.row + s.circle_dy[id],
					)
					s.pop_targets[id] = engine.coord(
						anchor.column + s.pop_offsets[id].column,
						anchor.row + s.pop_offsets[id].row,
					)
					s.pop_steps[id] = max(
						engine.round_to_int(
							engine.line_length(s.pop_targets[id], initial_coords[id], true) / 0.3,
						),
						1,
					)
				}
			}
		} else {
			age := s.tick - s.pop_starts[bi]
			remaining := 0
			color_tick := age >= 18 && age <= 66 && (age - 18) % 6 == 0
			fade_step := min((age - 18) / 6, 8) if color_tick else 0
			for id in members {
				expand_steps := s.expand_steps[id]
				move_age := age - expand_steps
				if age < expand_steps {
					engine.set_position(
						e,
						id,
						engine.tween(
							s.pop_origins[id],
							s.pop_targets[id],
							ease.ease(.Exponential_Out, f64(age + 1) / f64(expand_steps)),
						),
					)
				} else if move_age < s.pop_steps[id] {
					steps := s.pop_steps[id]
					coord := engine.tween(
						s.pop_targets[id],
						initial_coords[id],
						ease.ease(
							.Exponential_In_Out,
							f64(min(move_age + 1, steps)) / f64(steps),
						),
					)
					if move_age + 1 >= steps {
						engine.set_particle(e, id, coord, true, 0)
					} else {
						engine.set_position(e, id, coord)
					}
				}
				if age == 0 || age == 9 {
					engine.set_symbol(e, id, age < 9 ? '*' : '\'')
					if s.color_handling == .Dynamic {
						engine.set_foreground(e, id, s.config.pop_color)
					} else {
						engine.set_appearance(e, id, s.pop_code)
					}
				} else if color_tick {
					if age == 18 do engine.set_symbol(e, id, e.particles.initial_symbol[id])
					engine.set_appearance(e, id, engine.ramp_code(s.fades, s.final_index[id], fade_step))
				}
				final_ticks := s.color_handling == .Dynamic && s.uncolored_dynamic[id] ? 6 : 54
				if age + 1 < max(expand_steps + s.pop_steps[id], 18 + final_ticks) {
					members[remaining] = id
					remaining += 1
				}
			}
			s.bubbles.spans[bi].len = remaining
			if remaining == 0 do s.bubble_states[bi] = .Done
		}
		if s.bubble_states[bi] != .Done {
			s.active_bubbles[write] = bi
			write += 1
		}
	}
	resize(&s.active_bubbles, write)

	s.tick += 1
	return true
}
