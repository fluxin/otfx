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
	final_colors:       [dynamic]engine.Color,
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
	launcher_spectrum:  [dynamic]engine.Color,
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
	)
	defer delete(spectrum[:])
	text_sampler := engine.gradient_sampler(
		e.canvas.text_bottom,
		e.canvas.text_top,
		e.canvas.text_left,
		e.canvas.text_right,
		s.config.final_gradient_direction,
	)
	s.launcher_spectrum = engine.gradient_make(
		s.config.final_gradient_stops[:],
		s.config.final_gradient_steps[:],
		false,
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
	s.final_colors = make([dynamic]engine.Color, n)
	s.launch_starts = make([dynamic]int, n)
	s.launch_origins = make([dynamic]engine.Coord, n)
	s.launch_steps = make([dynamic]int, n)
	initial_coords := e.particles.initial_coord
	visible_flags := e.particles.flags
	for id, i in s.characters {
		s.final_colors[i] = engine.gradient_sample(text_sampler, spectrum[:], initial_coords[id])
		s.launch_starts[i] = -1
		visible_flags[id] -= {.Visible}
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
	index_by_id := make([dynamic]int, len(e.particles), context.temp_allocator)
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
	for i in 0 ..< 4 {
		appearance := engine.prepare_appearance(e, engine.Appearance{})
		id := engine.add_particle(e, s.launcher_symbols[i], appearance, starts[i])
		s.launcher_ids[i] = id
		s.launcher_positions[i] = starts[i]
		e.particles.layer[id] = 2
		e.particles.flags[id] += {.Visible}
	}
}

orbittingvolley_update_launchers :: proc(s: ^Orbittingvolley_State, e: ^engine.Engine) {
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
		engine.set_particle(e, id, p)
		engine.set_symbol(e, id, s.launcher_symbols[i])
		engine.set_foreground(
			e,
			id,
			engine.gradient_sample(s.launcher_sampler, s.launcher_spectrum[:], p),
		)
	}
}

orbittingvolley_next :: proc(s: ^Orbittingvolley_State, e: ^engine.Engine) -> bool {
	active := !s.launchers_hidden
	for i in s.active_indexes {
		if s.tick - s.launch_starts[i] < s.launch_steps[i] {
			active = true
			break
		}
	}
	if !active do return false

	magazines_left := false
	for i in 0 ..< 4 {
		if s.magazine_heads[i] < s.magazine_offsets[i + 1] do magazines_left = true
	}
	if magazines_left {
		orbittingvolley_update_launchers(s, e)
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
								e.particles.initial_coord[id],
								true,
							) /
							s.config.character_movement_speed,
						),
						1,
					)
					engine.set_particle(e, id, s.launch_origins[i])
					engine.set_particle(e, id, engine.Layer(1))
					engine.set_particle(e, id, engine.Visible(true))
				}
			}
			s.delay = s.config.launch_delay
		} else {
			s.delay -= 1
		}
	} else if !s.launchers_hidden {
		for id in s.launcher_ids {
			engine.set_particle(e, id, engine.Visible(false))
		}
		s.launchers_hidden = true
	}

	initial_coords := e.particles.initial_coord

	write := 0
	for i in s.active_indexes {
		id := s.characters[i]
		start := s.launch_starts[i]
		age := s.tick - start
		steps := s.launch_steps[i]
		if age >= steps {
			// Preserve the layer transition one tick after the final motion sample.
			if age == steps {
				engine.set_particle(e, id, engine.Layer(0))
			}
			continue
		}
		s.active_indexes[write] = i
		write += 1
		engine.set_particle(
			e,
			id,
			engine.coord_on_line(
				s.launch_origins[i],
				initial_coords[id],
				ease.ease(s.config.character_easing, f64(age + 1) / f64(steps)),
			),
		)
		if age == 0 {
			if s.color_handling == .Dynamic {
				appearance := engine.get_appearance(e, id)
				engine.dynamic_apply_input_colors(
					&appearance,
					engine.get_initial_appearance(e, engine.Particle_Id(id)),
				)
				engine.set_appearance(e, id, appearance)
			} else {
				engine.set_foreground(e, id, s.final_colors[i])
			}
		}
	}
	resize(&s.active_indexes, write)
	s.tick += 1
	return true
}
