package effects

import engine "../engine"

import "core:fmt"
import "core:math/ease"

Orbittingvolley_Config :: struct {
	top_launcher_symbol:      rune,
	right_launcher_symbol:    rune,
	bottom_launcher_symbol:   rune,
	left_launcher_symbol:     rune,
	launcher_movement_speed:  f64,
	character_movement_speed: f64,
	volley_size:              f64,
	launch_delay:             int,
	character_easing:         ease.Ease,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

orbittingvolley_config_default :: proc() -> Orbittingvolley_Config {
	cfg := Orbittingvolley_Config {
		top_launcher_symbol      = '█',
		right_launcher_symbol    = '█',
		bottom_launcher_symbol   = '█',
		left_launcher_symbol     = '█',
		launcher_movement_speed  = 0.8,
		character_movement_speed = 1.5,
		volley_size              = 0.03,
		launch_delay             = 30,
		character_easing         = .Sine_Out,
		final_gradient_direction = .Radial,
	}
	append(
		&cfg.final_gradient_stops,
		engine.Color{0xFF, 0xA1, 0x5C},
		engine.Color{0x44, 0xD4, 0x92},
	)
	append(&cfg.final_gradient_steps, 12)
	return cfg
}

orbittingvolley_parse :: proc(cfg: ^Orbittingvolley_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--top-launcher-symbol":
			if !parse_symbol_flag(&cfg.top_launcher_symbol, args, &i, value, has_value) do return false
		case "--right-launcher-symbol":
			if !parse_symbol_flag(&cfg.right_launcher_symbol, args, &i, value, has_value) do return false
		case "--bottom-launcher-symbol":
			if !parse_symbol_flag(&cfg.bottom_launcher_symbol, args, &i, value, has_value) do return false
		case "--left-launcher-symbol":
			if !parse_symbol_flag(&cfg.left_launcher_symbol, args, &i, value, has_value) do return false
		case "--launcher-movement-speed":
			if !parse_float_flag(&cfg.launcher_movement_speed, args, &i, value, has_value) || cfg.launcher_movement_speed <= 0 do return false
		case "--character-movement-speed":
			if !parse_float_flag(&cfg.character_movement_speed, args, &i, value, has_value) || cfg.character_movement_speed <= 0 do return false
		case "--volley-size":
			if !parse_float_flag(&cfg.volley_size, args, &i, value, has_value) || cfg.volley_size < 0 || cfg.volley_size > 1 do return false
		case "--launch-delay":
			if !parse_int_flag(&cfg.launch_delay, args, &i, value, has_value, minimum = 0) || cfg.launch_delay < 0 do return false
		case "--character-easing":
			if !parse_ease_flag(&cfg.character_easing, args, &i, value, has_value) do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown orbittingvolley option: ", name)
			return false
		}
	}
	return true
}

Orbittingvolley_State :: struct {
	config:             Orbittingvolley_Config,
	characters:         [dynamic]engine.Particle_Id,
	final_codes:        [dynamic]engine.Appearance_Id,
	targets:            [dynamic]engine.Coord,
	active_indexes:     [dynamic]int,
	launch_starts:      [dynamic]int,
	launch_origins:     [dynamic]engine.Coord,
	launch_steps:       [dynamic]int,
	magazines:          [dynamic]int, // character indices, four contiguous spans
	magazine_offsets:   [5]int,
	magazine_heads:     [4]int,
	launcher_ids:       [4]engine.Particle_Id,
	launcher_positions: [4]engine.Coord,
	launcher_symbols:   [4]rune,
	spectrum_codes:     [dynamic]engine.Appearance_Id,
	launcher_sampler:   engine.Gradient_Sampler,
	launcher_advance:   f64,
	delay:              int,
	tick:               int,
	launchers_hidden:   bool,
	color_handling:     engine.Existing_Color_Handling,
}

orbittingvolley_build :: proc(s: ^Orbittingvolley_State, e: ^engine.Engine) {
	s.color_handling = e.cfg.existing_color_handling
	spectrum := engine.gradient_make(
		s.config.final_gradient_stops[:],
		s.config.final_gradient_steps[:],
		false,
		context.temp_allocator,
	)
	defer delete(spectrum)
	s.spectrum_codes = make([dynamic]engine.Appearance_Id, len(spectrum))
	for color, ci in spectrum {
		if ci > 0 && color == spectrum[ci - 1] {
			s.spectrum_codes[ci] = s.spectrum_codes[ci - 1]
		} else {
			s.spectrum_codes[ci] = engine.prepare_appearance(e, engine.Appearance{colors = {fg = color}})
		}
	}
	text_sampler := engine.gradient_sampler(
		e.canvas.text_bottom,
		e.canvas.text_top,
		e.canvas.text_left,
		e.canvas.text_right,
		s.config.final_gradient_direction,
	)
	s.launcher_sampler = engine.gradient_sampler(
		e.canvas.bottom,
		e.canvas.top,
		e.canvas.left,
		e.canvas.right,
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
	n := len(s.characters)
	reserve(&s.active_indexes, n)
	s.final_codes = make([dynamic]engine.Appearance_Id, n)
	s.targets = make([dynamic]engine.Coord, n)
	s.launch_starts = make([dynamic]int, n)
	s.launch_origins = make([dynamic]engine.Coord, n)
	s.launch_steps = make([dynamic]int, n)
	initial_coords := e.particles.initial_coord
	visible_flags := e.particles.flags
	if s.color_handling == .Dynamic && n > 0 {
		dyn_styles := make([]engine.Appearance, n, context.temp_allocator)
		defer delete(dyn_styles, context.temp_allocator)
		for id, i in s.characters {
			s.targets[i] = initial_coords[id]
			s.launch_starts[i] = -1
			visible_flags[id] -= {.Visible}
			init_style := engine.get_initial_appearance(e, id)
			dyn_styles[i] = {colors = init_style.colors, bold = init_style.bold}
		}
		unique_styles, style_indices := engine.group_values(dyn_styles)
		defer delete(unique_styles)
		defer delete(style_indices)
		unique_codes := make([]engine.Appearance_Id, len(unique_styles), context.temp_allocator)
		defer delete(unique_codes, context.temp_allocator)
		for style, idx in unique_styles do unique_codes[idx] = engine.prepare_appearance(e, style)
		for i in 0 ..< n do s.final_codes[i] = unique_codes[style_indices[i]]
	} else {
		for id, i in s.characters {
			c := initial_coords[id]
			s.targets[i] = c
			s.final_codes[i] = s.spectrum_codes[engine.gradient_sample_index(text_sampler, len(s.spectrum_codes), c)]
			s.launch_starts[i] = -1
			visible_flags[id] -= {.Visible}
		}
	}

	// Center-to-outside source ordering, then branch-wrapped round-robin
	// assignment into four flat magazine spans.
	center_groups := engine.get_particles_grouped(
		query,
		engine.PARTICLE_FILTER_INPUT,
		.Center_Outside,
	)
	defer engine.groups_delete(&center_groups)
	counts: [4]int
	launcher := 0
	for _ in center_groups.members {
		counts[launcher] += 1
		launcher += 1
		if launcher == 4 do launcher = 0
	}
	s.magazine_offsets[0] = 0
	for i in 0 ..< 4 do s.magazine_offsets[i + 1] = s.magazine_offsets[i] + counts[i]
	for i in 0 ..< 4 do s.magazine_heads[i] = s.magazine_offsets[i]
	s.magazines = make([dynamic]int, n)
	// Filling each magazine advances local cursors only. Borrowing the offset
	// prefix here would corrupt the immutable span boundaries used at runtime.
	cursors: [4]int
	for i in 0 ..< 4 do cursors[i] = s.magazine_offsets[i]
	index_by_id := make([]int, len(e.particles), context.temp_allocator)
	defer delete(index_by_id, context.temp_allocator)
	for id, i in s.characters do index_by_id[id] = i
	launcher = 0
	for id in center_groups.members {
		s.magazines[cursors[launcher]] = index_by_id[id]
		cursors[launcher] += 1
		launcher += 1
		if launcher == 4 do launcher = 0
	}

	s.launcher_symbols = {
		s.config.top_launcher_symbol,
		s.config.right_launcher_symbol,
		s.config.bottom_launcher_symbol,
		s.config.left_launcher_symbol,
	}
	starts := [4]engine.Coord {
		engine.coord(e.canvas.left, e.canvas.top),
		engine.coord(e.canvas.right, e.canvas.top),
		engine.coord(e.canvas.right, e.canvas.bottom),
		engine.coord(e.canvas.left, e.canvas.bottom),
	}
	plain := engine.prepare_appearance(e, engine.Appearance{})
	launchers := engine.particle_batch(e, 4)
	for i in 0 ..< 4 {
		id := engine.add_particle(&launchers, s.launcher_symbols[i], plain, starts[i])
		s.launcher_ids[i] = id
		s.launcher_positions[i] = starts[i]
		e.particles.layer[id] = 2
		e.particles.flags[id] += {.Visible}
	}
}

orbittingvolley_update_launchers :: proc(s: ^Orbittingvolley_State, e: ^engine.Engine) #no_bounds_check {
	// The primary launcher traverses the top edge. The other three are its
	// phase-shifted perimeter children, matching the original visible orbit.
	s.launcher_advance += s.config.launcher_movement_speed
	width := e.canvas.right - e.canvas.left + 1
	for s.launcher_advance >= f64(width) do s.launcher_advance -= f64(width)
	progress := s.launcher_advance / f64(max(width - 1, 1))
	col := e.canvas.left + int(s.launcher_advance)
	s.launcher_positions[0] = engine.coord(col, e.canvas.top)
	s.launcher_positions[1] = engine.coord(
		e.canvas.right,
		e.canvas.top - engine.round_to_int(progress * f64(e.canvas.top - e.canvas.bottom)),
	)
	s.launcher_positions[2] = engine.coord(
		e.canvas.right - engine.round_to_int(progress * f64(e.canvas.right - e.canvas.left)),
		e.canvas.bottom,
	)
	s.launcher_positions[3] = engine.coord(
		e.canvas.left,
		e.canvas.bottom + engine.round_to_int(progress * f64(e.canvas.top - e.canvas.bottom)),
	)
	for i in 0 ..< 4 {
		id := s.launcher_ids[i]
		p := s.launcher_positions[i]
		engine.set_position(e, id, p)
		engine.set_appearance(
			e,
			id,
			s.spectrum_codes[engine.gradient_sample_index(s.launcher_sampler, len(s.spectrum_codes), p)],
		)
	}
}

orbittingvolley_next :: proc(s: ^Orbittingvolley_State, e: ^engine.Engine) -> bool #no_bounds_check {
	magazines_left := false
	for i in 0 ..< 4 {
		if s.magazine_heads[i] < s.magazine_offsets[i + 1] do magazines_left = true
	}
	if !magazines_left && len(s.active_indexes) == 0 {
		if s.launchers_hidden do return false
		for id in s.launcher_ids {
			engine.set_particle(e, id, engine.Visible(false))
		}
		s.launchers_hidden = true
		s.tick += 1
		return true
	}

	orbittingvolley_update_launchers(s, e)
	if magazines_left {
		if s.delay == 0 {
			per_launcher := max(int(s.config.volley_size * f64(len(s.characters)) / 4), 1)
			for launcher in 0 ..< 4 {
				for _ in 0 ..< per_launcher {
					head := s.magazine_heads[launcher]
					if head == s.magazine_offsets[launcher + 1] do break
					i := s.magazines[head]
					s.magazine_heads[launcher] += 1
					s.launch_starts[i] = s.tick
					append(&s.active_indexes, i)
					s.launch_origins[i] = s.launcher_positions[launcher]
					id := s.characters[i]
					s.launch_steps[i] = max(
						engine.round_to_int(
							engine.line_length(
								s.launch_origins[i],
								s.targets[i],
								true,
							) /
							s.config.character_movement_speed,
						),
						1,
					)
					engine.set_particle(e, id, s.launch_origins[i], true, 1)
				}
			}
			s.delay = s.config.launch_delay
		} else {
			s.delay -= 1
		}
	}

	write := 0
	for i in s.active_indexes {
		id := s.characters[i]
		start := s.launch_starts[i]
		age := s.tick - start
		steps := s.launch_steps[i]
		if age >= steps do continue
		engine.set_position(
			e,
			id,
			engine.tween(
				s.launch_origins[i],
				s.targets[i],
				ease.ease(s.config.character_easing, f64(age + 1) / f64(steps)),
			),
		)
		if age == 0 {
			engine.set_appearance(e, id, s.final_codes[i])
		}
		if age + 1 == steps {
			engine.set_particle(e, id, engine.Layer(0))
		} else {
			s.active_indexes[write] = i
			write += 1
		}
	}
	resize(&s.active_indexes, write)
	s.tick += 1
	return true
}
