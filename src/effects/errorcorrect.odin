package effects

import "../engine"
import "core:fmt"

@(private, rodata)
Errorcorrect_First_Wipe: [8]rune = {'▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'}

@(private, rodata)
Errorcorrect_Last_Wipe: [7]rune = {'▇', '▆', '▅', '▄', '▃', '▂', '▁'}

Errorcorrect_Config :: struct {
	error_pairs:              f64,
	swap_delay:               int,
	error_color:              engine.Color,
	correct_color:            engine.Color,
	movement_speed:           f64,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

errorcorrect_config_default :: proc() -> Errorcorrect_Config {
	cfg := Errorcorrect_Config {
		error_pairs              = 0.1,
		swap_delay               = 6,
		error_color              = {0xe7, 0x4c, 0x3c},
		correct_color            = {0x45, 0xbf, 0x55},
		movement_speed           = 0.9,
		final_gradient_direction = .Vertical,
	}
	append(
		&cfg.final_gradient_stops,
		..[]engine.Color{{0x8A, 0x00, 0x8A}, {0x00, 0xD1, 0xFF}, {0xFF, 0xFF, 0xFF}},
	)
	append(&cfg.final_gradient_steps, 12)
	return cfg
}

errorcorrect_parse :: proc(cfg: ^Errorcorrect_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--error-pairs":
			if !parse_float_flag(&cfg.error_pairs, args, &i, value, has_value) || cfg.error_pairs <= 0 do return false
		case "--swap-delay":
			if !parse_int_flag(&cfg.swap_delay, args, &i, value, has_value) || cfg.swap_delay <= 0 do return false
		case "--error-color":
			if !parse_color_flag(&cfg.error_color, args, &i, value, has_value) do return false
		case "--correct-color":
			if !parse_color_flag(&cfg.correct_color, args, &i, value, has_value) do return false
		case "--movement-speed":
			if !parse_float_flag(&cfg.movement_speed, args, &i, value, has_value) || cfg.movement_speed <= 0 do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown errorcorrect option: ", name); return false
		}
	}
	return true
}

Errorcorrect_Pair :: struct {
	first, second: engine.Particle_Id,
}

// One flat active-id column; each id's phase is derived from its start tick.
Errorcorrect_State :: struct {
	config:         Errorcorrect_Config,
	swapped:        [dynamic]Errorcorrect_Pair,
	swapped_head:   int,
	final_ramp:     engine.Appearance_Ramp,
	fade_index:     [dynamic]int,
	move_codes:     [11]engine.Appearance_Id,
	error_code:     engine.Appearance_Id,
	white_code:     engine.Appearance_Id,
	correct_code:   engine.Appearance_Id,
	origins:        [dynamic]engine.Coord,
	max_steps:      [dynamic]int,
	start_ticks:    [dynamic]int,
	active:         [dynamic]engine.Particle_Id,
	swap_delay:     int,
	tick:           int,
	color_handling: engine.Existing_Color_Handling,
}

errorcorrect_build :: proc(s: ^Errorcorrect_State, e: ^engine.Engine) {
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
	characters := engine.get_particles(
		engine.Particle_Query {
			e.particle_sets,
			e.particles.initial_coord[:len(e.particles)],
			e.canvas,
		},
		engine.PARTICLE_FILTER_INPUT,
		.Top_Bottom_Left_Right,
	)
	defer delete(characters)
	storage_len := len(e.particles)
	s.color_handling = e.cfg.existing_color_handling
	s.fade_index = make([dynamic]int, storage_len)
	s.origins = make([dynamic]engine.Coord, storage_len)
	s.max_steps = make([dynamic]int, storage_len)
	s.start_ticks = make([dynamic]int, storage_len)
	for i in 0 ..< storage_len do s.start_ticks[i] = -1
	if len(characters) == 0 do return

	s.error_code = engine.prepare_appearance(e, {colors = {fg = s.config.error_color}})
	s.white_code = engine.prepare_appearance(e, {colors = {fg = engine.Color{0xff, 0xff, 0xff}}})
	s.correct_code = engine.prepare_appearance(e, {colors = {fg = s.config.correct_color}})
	s.move_codes[0] = s.error_code
	s.move_codes[10] = s.correct_code
	for step in 1 ..= 9 {
		c := engine.tween(s.config.error_color, s.config.correct_color, 10, step)
		s.move_codes[step] = engine.prepare_appearance(e, {colors = {fg = c}})
	}

	fade_tweens := make([]engine.Tween(engine.Appearance), len(characters), context.temp_allocator)
	defer delete(fade_tweens, context.temp_allocator)
	correct := s.config.correct_color
	for id, k in characters {
		if s.color_handling == .Dynamic {
			init_style := engine.get_initial_appearance(e, id)
			fade_tweens[k] = {
				from = {colors = {correct, correct}},
				to   = {colors = init_style.colors},
			}
		} else {
			fc := engine.gradient_sample(sampler, spectrum[:], e.particles.initial_coord[id])
			fade_tweens[k] = {
				from = {colors = {fg = correct}},
				to   = {colors = {fg = fc}},
			}
		}
	}
	unique_tweens, indices := engine.group_values(fade_tweens)
	defer delete(unique_tweens)
	defer delete(indices)
	s.final_ramp = engine.ramp_make(e, unique_tweens[:], 10)
	for id, k in characters {
		idx := indices[k]
		s.fade_index[id] = idx
		engine.set_symbol(e, id, e.particles.initial_symbol[id])
		engine.set_appearance(e, id, engine.ramp_code(s.final_ramp, idx, 10))
		e.particles.flags[id] += {.Visible}
	}

	available := make([dynamic]engine.Particle_Id, 0, len(characters), context.temp_allocator)
	defer delete(available)
	append(&available, ..characters[:])
	for _ in 0 ..< int(s.config.error_pairs * f64(len(characters))) {
		if len(available) < 2 do break
		first_index := engine.random_below(len(available))
		first := available[first_index]
		ordered_remove(&available, first_index)
		second_index := engine.random_below(len(available))
		second := available[second_index]
		ordered_remove(&available, second_index)
		first_home, second_home :=
			e.particles.initial_coord[first], e.particles.initial_coord[second]
		s.origins[first], s.origins[second] = second_home, first_home
		e.particles.current_coord[first], e.particles.current_coord[second] =
			second_home, first_home
		s.max_steps[first] = max(
			engine.round_to_int(
				engine.line_length(second_home, first_home, true) / s.config.movement_speed,
			),
			1,
		)
		s.max_steps[second] = max(
			engine.round_to_int(
				engine.line_length(first_home, second_home, true) / s.config.movement_speed,
			),
			1,
		)
		// A swapped pair has to read as an error from the first frame.
		if s.color_handling == .Dynamic {
			// Preserve input bg if present during initial swapped hold, matching set_foreground.
			first_bg := engine.get_initial_appearance(e, first).colors.bg
			second_bg := engine.get_initial_appearance(e, second).colors.bg
			engine.set_appearance(
				e,
				first,
				first_bg == nil ? s.error_code : engine.prepare_appearance(e, {colors = {fg = s.config.error_color, bg = first_bg}}),
			)
			engine.set_appearance(
				e,
				second,
				second_bg == nil ? s.error_code : engine.prepare_appearance(e, {colors = {fg = s.config.error_color, bg = second_bg}}),
			)
		} else {
			engine.set_appearance(e, first, s.error_code)
			engine.set_appearance(e, second, s.error_code)
		}
		append(&s.swapped, Errorcorrect_Pair{first, second})
	}
	reserve(&s.active, 2 * len(s.swapped))
}

errorcorrect_next :: proc(s: ^Errorcorrect_State, e: ^engine.Engine) -> bool #no_bounds_check {
	if s.swapped_head < len(s.swapped) && s.swap_delay == 0 {
		pair := s.swapped[s.swapped_head]; s.swapped_head += 1
		s.start_ticks[pair.first] = s.tick
		s.start_ticks[pair.second] = s.tick
		append(&s.active, pair.first, pair.second)
		s.swap_delay = s.config.swap_delay
	} else if s.swap_delay != 0 do s.swap_delay -= 1
	if len(s.active) == 0 do return false
	first_wipe := Errorcorrect_First_Wipe
	last_wipe := Errorcorrect_Last_Wipe
	dynamic_mode := s.color_handling == .Dynamic
	write := 0
	for id in s.active {
		age, motion_start := s.tick - s.start_ticks[id], 84
		last_start := motion_start + s.max_steps[id] - 1
		total := s.max_steps[id] + 137
		if age >= total do continue
		s.active[write] = id; write += 1
		switch {
		case age < 60:
			if age % 3 != 0 do continue
			if (age / 3) % 2 == 0 {
				engine.set_symbol(e, id, '▓')
				if dynamic_mode && engine.get_initial_appearance(e, id).colors.bg != nil {
					engine.set_foreground(e, id, s.config.error_color)
				} else {
					engine.set_appearance(e, id, s.error_code)
				}
			} else {
				engine.set_symbol(e, id, e.particles.initial_symbol[id])
				if dynamic_mode && engine.get_initial_appearance(e, id).colors.bg != nil {
					engine.set_foreground(e, id, engine.Color{0xff, 0xff, 0xff})
				} else {
					engine.set_appearance(e, id, s.white_code)
				}
			}
		case age < 84:
			if age % 3 != 0 do continue
			engine.set_symbol(e, id, first_wipe[(age - 60) / 3])
			if dynamic_mode && engine.get_initial_appearance(e, id).colors.bg != nil {
				engine.set_foreground(e, id, s.config.error_color)
			} else {
				engine.set_appearance(e, id, s.error_code)
			}
		case age < last_start:
			progress := f64(age - motion_start + 1) / f64(s.max_steps[id])
			engine.set_placement(
				e,
				id,
				engine.tween(s.origins[id], e.particles.initial_coord[id], progress),
				true,
				1,
			)
			engine.set_symbol(e, id, '█')
			move_step := min(engine.round_to_int(progress * 10), 10)
			if dynamic_mode && engine.get_initial_appearance(e, id).colors.bg != nil {
				engine.set_foreground(
					e,
					id,
					engine.tween(s.config.error_color, s.config.correct_color, 10, move_step),
				)
			} else {
				engine.set_appearance(e, id, s.move_codes[move_step])
			}
		case age < last_start + 21:
			if (age - last_start) % 3 != 0 do continue
			if age == last_start {
				engine.set_placement(e, id, e.particles.initial_coord[id], true, 0)
			}
			engine.set_symbol(e, id, last_wipe[(age - last_start) / 3])
			if dynamic_mode && engine.get_initial_appearance(e, id).colors.bg != nil {
				engine.set_foreground(e, id, s.config.correct_color)
			} else {
				engine.set_appearance(e, id, s.correct_code)
			}
		case:
			if (age - last_start - 21) % 3 != 0 do continue
			engine.set_symbol(e, id, e.particles.initial_symbol[id])
			step := min((age - last_start - 21) / 3, 10)
			engine.set_appearance(e, id, engine.ramp_code(s.final_ramp, s.fade_index[id], step))
		}
	}
	resize(&s.active, write)
	s.tick += 1
	return true
}
