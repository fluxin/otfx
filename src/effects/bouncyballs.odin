package effects

import engine "../engine"

import "core:fmt"
import "core:math/ease"

Bouncyballs_Config :: struct {
	ball_colors:              [dynamic]engine.Color,
	ball_symbols:             [dynamic]rune,
	ball_delay:               int,
	movement_speed:           f64,
	movement_easing:          ease.Ease,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

bouncyballs_config_default :: proc() -> Bouncyballs_Config {
	cfg := Bouncyballs_Config {
		ball_delay               = 4,
		movement_speed           = 0.45,
		movement_easing          = .Bounce_Out,
		final_gradient_direction = .Diagonal,
	}
	append(
		&cfg.ball_colors,
		..[]engine.Color {
			engine.Color{0xd1, 0xf4, 0xa5},
			engine.Color{0x96, 0xe2, 0xa4},
			engine.Color{0x5a, 0xcd, 0xa9},
		},
	)
	append(&cfg.ball_symbols, ..[]rune{'*', 'o', 'O', '0', '.'})
	append(
		&cfg.final_gradient_stops,
		..[]engine.Color{engine.Color{0xf8, 0xff, 0xae}, engine.Color{0x43, 0xc6, 0xac}},
	)
	append(&cfg.final_gradient_steps, 12)
	return cfg
}

bouncyballs_parse :: proc(cfg: ^Bouncyballs_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--ball-colors":
			if !parse_colors_flag(&cfg.ball_colors, args, &i, value, has_value) do return false
		case "--ball-symbols":
			if !parse_symbols_flag(&cfg.ball_symbols, args, &i, value, has_value) do return false
		case "--ball-delay":
			if !parse_int_flag(&cfg.ball_delay, args, &i, value, has_value, minimum = 0) || cfg.ball_delay < 0 do return false
		case "--movement-speed":
			if !parse_float_flag(&cfg.movement_speed, args, &i, value, has_value) || cfg.movement_speed <= 0 do return false
		case "--movement-easing":
			if !parse_ease_flag(&cfg.movement_easing, args, &i, value, has_value) do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown bouncyballs option: ", name)
			return false
		}
	}
	return true
}

Bouncyballs_State :: struct {
	config:         Bouncyballs_Config,
	characters:     [dynamic]engine.Particle_Id,
	index_by_id:    [dynamic]int,
	ball_codes:     [dynamic]engine.Appearance_Id,
	fades:          engine.Appearance_Ramp,
	fade_index:     [dynamic]int,
	ball_symbols:   [dynamic]rune,
	origins:        [dynamic]engine.Coord,
	targets:        [dynamic]engine.Coord,
	max_steps:      [dynamic]int,
	start_ticks:    [dynamic]int,
	row_groups:     engine.Particle_Groups,
	next_group:     int,
	pending:        [dynamic]engine.Particle_Id,
	active_slots:   [dynamic]int,
	ball_delay:     int,
	tick:           int,
	color_handling: engine.Existing_Color_Handling,
}

bouncyballs_build :: proc(s: ^Bouncyballs_State, e: ^engine.Engine) {
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
	s.row_groups = engine.get_particles_grouped(query, engine.PARTICLE_FILTER_INPUT, .Row_B2T)
	n := len(s.characters)
	reserve(&s.active_slots, n)
	pending_capacity := 0
	for span in s.row_groups.spans do pending_capacity = max(pending_capacity, span.len)
	reserve(&s.pending, pending_capacity)
	s.color_handling = e.cfg.existing_color_handling
	s.index_by_id = make([dynamic]int, len(e.particles))
	s.ball_codes = make([dynamic]engine.Appearance_Id, n)
	s.ball_symbols = make([dynamic]rune, n)
	s.origins = make([dynamic]engine.Coord, n)
	s.targets = make([dynamic]engine.Coord, n)
	s.max_steps = make([dynamic]int, n)
	s.start_ticks = make([dynamic]int, n)
	if n == 0 do return

	ball_styles := make([]engine.Appearance, n, context.temp_allocator)
	fade_tweens := make([]engine.Tween(engine.Appearance), n, context.temp_allocator)
	defer delete(ball_styles, context.temp_allocator)
	defer delete(fade_tweens, context.temp_allocator)

	for id, i in s.characters {
		s.index_by_id[id] = i
		initial_coord := e.particles.initial_coord[id]
		s.targets[i] = initial_coord
		ball_color := s.config.ball_colors[engine.random_below(len(s.config.ball_colors))]
		s.ball_symbols[i] = s.config.ball_symbols[engine.random_below(len(s.config.ball_symbols))]
		final_color := engine.gradient_sample(sampler, spectrum[:], initial_coord)
		if s.color_handling == .Dynamic {
			init_style := engine.get_initial_appearance(e, id)
			ball_styles[i] = {
				colors = {fg = ball_color, bg = init_style.colors.bg},
				bold   = init_style.bold,
			}
			fade_tweens[i] = {
				from = {colors = {ball_color, ball_color}, bold = init_style.bold},
				to   = {colors = init_style.colors, bold = init_style.bold},
			}
		} else {
			ball_styles[i] = {colors = {fg = ball_color}}
			fade_tweens[i] = {
				from = {colors = {fg = ball_color}},
				to   = {colors = {fg = final_color}},
			}
		}
		drop_row := int(f64(e.canvas.top) * engine.random_float_range(1, 1.5))
		s.origins[i] = engine.coord(initial_coord.column, drop_row)
		e.particles.current_coord[id] = s.origins[i]
		s.max_steps[i] = max(
			engine.round_to_int(
				engine.line_length(s.origins[i], initial_coord, true) / s.config.movement_speed,
			),
			1,
		)
		s.start_ticks[i] = -1
	}

	unique_balls, ball_indices := engine.group_values(ball_styles)
	defer delete(unique_balls)
	defer delete(ball_indices)
	unique_ball_codes := make([]engine.Appearance_Id, len(unique_balls), context.temp_allocator)
	defer delete(unique_ball_codes, context.temp_allocator)
	for style, idx in unique_balls {
		unique_ball_codes[idx] = engine.prepare_appearance(e, style)
	}
	for i in 0 ..< n do s.ball_codes[i] = unique_ball_codes[ball_indices[i]]

	unique_tweens: [dynamic]engine.Tween(engine.Appearance)
	unique_tweens, s.fade_index = engine.group_values(fade_tweens)
	defer delete(unique_tweens)
	s.fades = engine.ramp_make(e, unique_tweens[:], 10)
}

bouncyballs_next :: proc(s: ^Bouncyballs_State, e: ^engine.Engine) -> bool #no_bounds_check {
	active :=
		s.next_group < len(s.row_groups.spans) || len(s.pending) > 0 || len(s.active_slots) > 0
	if !active do return false
	if len(s.pending) == 0 && s.next_group < len(s.row_groups.spans) {
		append(&s.pending, ..engine.group_members(s.row_groups, s.next_group))
		s.next_group += 1
	}
	if len(s.pending) > 0 {
		if s.ball_delay == 0 {
			for _ in 0 ..< engine.random_range(2, 7) {
				if len(s.pending) == 0 do break
				index := engine.random_below(len(s.pending))
				id := s.pending[index]
				unordered_remove(&s.pending, index)
				slot := s.index_by_id[id]
				s.start_ticks[slot] = s.tick
				append(&s.active_slots, slot)
				engine.set_particle(e, id, engine.Visible(true))
			}
			s.ball_delay = s.config.ball_delay
		} else {
			s.ball_delay -= 1
		}
	}
	write := 0
	for slot in s.active_slots {
		id := s.characters[slot]
		age := s.tick - s.start_ticks[slot]
		max_steps := s.max_steps[slot]
		if age >= max_steps + 65 do continue
		if age < max_steps - 1 {
			progress := f64(age + 1) / f64(max_steps)
			engine.set_position(
				e,
				id,
				engine.tween(
					s.origins[slot],
					s.targets[slot],
					ease.ease(s.config.movement_easing, progress),
				),
			)
			if age == 0 {
				engine.set_symbol(e, id, s.ball_symbols[slot])
				engine.set_appearance(e, id, s.ball_codes[slot])
			}
		} else {
			if age == max_steps - 1 {
				engine.set_position(e, id, s.targets[slot])
				engine.set_symbol(e, id, e.particles.initial_symbol[id])
			}
			fade_tick := age - (max_steps - 1)
			if fade_tick <= 60 && fade_tick % 6 == 0 {
				engine.set_appearance(
					e,
					id,
					engine.ramp_code(s.fades, s.fade_index[slot], min(fade_tick / 6, 10)),
				)
			}
		}
		if age + 1 < max_steps + 65 {
			s.active_slots[write] = slot
			write += 1
		}
	}
	resize(&s.active_slots, write)
	s.tick += 1
	return true
}
