package effects

import "../engine"

import "core:fmt"
import "core:math/ease"

Unstable_Config :: struct {
	unstable_color:           engine.Color,
	explosion_ease:           ease.Ease,
	explosion_speed:          f64,
	reassembly_ease:          ease.Ease,
	reassembly_speed:         f64,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

unstable_config_default :: proc() -> Unstable_Config {
	cfg := Unstable_Config {
		unstable_color           = engine.Color{0xff, 0x92, 0x00},
		explosion_ease           = .Exponential_Out,
		explosion_speed          = 1,
		reassembly_ease          = .Exponential_Out,
		reassembly_speed         = 1,
		final_gradient_direction = .Vertical,
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

unstable_parse :: proc(cfg: ^Unstable_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--unstable-color":
			if !parse_color_flag(&cfg.unstable_color, args, &i, value, has_value) do return false
		case "--explosion-ease":
			if !parse_ease_flag(&cfg.explosion_ease, args, &i, value, has_value) do return false
		case "--explosion-speed":
			if !parse_float_flag(&cfg.explosion_speed, args, &i, value, has_value) || cfg.explosion_speed <= 0 do return false
		case "--reassembly-ease":
			if !parse_ease_flag(&cfg.reassembly_ease, args, &i, value, has_value) do return false
		case "--reassembly-speed":
			if !parse_float_flag(&cfg.reassembly_speed, args, &i, value, has_value) || cfg.reassembly_speed <= 0 do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown unstable option: ", name)
			return false
		}
	}
	return true
}

Unstable_Phase :: enum {
	Rumble,
	Explosion,
	Explosion_Hold,
	Reassembly,
}

// Coordinates and slots are parallel to characters. Each phase shares one
// easing result per distinct duration; slots connect particles to those results.
Unstable_State :: struct {
	config:              Unstable_Config,
	characters:          [dynamic]engine.Particle_Id,
	active_indexes:      [dynamic]int,
	jumbled_coords:      [dynamic]engine.Coord,
	explosion_targets:   [dynamic]engine.Coord,
	final_colors:        [dynamic]engine.Color,
	explosion_slots:     [dynamic]int,
	explosion_factors:   [dynamic]f64,
	explosion_steps:     [dynamic]int,
	reassembly_slots:    [dynamic]int,
	reassembly_factors:  [dynamic]f64,
	reassembly_steps:    [dynamic]int,
	phase:               Unstable_Phase,
	phase_tick:          int,
	explosion_max_steps: int,
	reassembly_limit:    int,
	rumble_offset:       engine.Coord,
	rumble_delay:        int,
	color_handling:      engine.Existing_Color_Handling,
}

unstable_build :: proc(s: ^Unstable_State, e: ^engine.Engine) {
	spectrum := engine.gradient_make(
		s.config.final_gradient_stops[:],
		s.config.final_gradient_steps[:],
		false,
	)
	defer delete(spectrum[:])
	sampler := engine.gradient_sampler(
		e.canvas.text_bottom,
		e.canvas.text_top,
		e.canvas.text_left,
		e.canvas.text_right,
		s.config.final_gradient_direction,
	)

	s.characters = engine.get_particles(
		engine.Particle_Query {
			e.particle_sets,
			e.particles.initial_coord[:len(e.particles)],
			e.canvas,
		},
		engine.PARTICLE_FILTER_INPUT,
		.Top_Bottom_Left_Right,
	)
	n := len(s.characters)
	s.color_handling = e.cfg.existing_color_handling
	s.jumbled_coords = make([dynamic]engine.Coord, n)
	s.explosion_targets = make([dynamic]engine.Coord, n)
	s.final_colors = make([dynamic]engine.Color, n)
	explosion_steps := make([]int, n, context.temp_allocator)
	reassembly_steps := make([]int, n, context.temp_allocator)
	s.active_indexes = make([dynamic]int, n)
	// Thirteen color entries last three frames each; some dynamic colors restore at 39.
	s.reassembly_limit = 39

	// This is a bounded temporary permutation of input locations. Its order has
	// no semantic meaning, so unordered removal keeps the shuffle O(n).
	available := make([dynamic]engine.Coord, n, context.temp_allocator)
	initial_coords := e.particles.initial_coord
	for id, i in s.characters do available[i] = initial_coords[id]

	current_coords := e.particles.current_coord
	visible_flags := e.particles.flags

	for id, i in s.characters {
		s.active_indexes[i] = i
		edge := engine.random_below(4)
		target: engine.Coord
		switch edge {
		case 0:
			target = engine.coord(e.canvas.left, engine.canvas_random_row(e.canvas, false))
		case 1:
			target = engine.coord(e.canvas.right, engine.canvas_random_row(e.canvas, false))
		case 2:
			target = engine.coord(engine.canvas_random_column(e.canvas, false), e.canvas.bottom)
		case:
			target = engine.coord(engine.canvas_random_column(e.canvas, false), e.canvas.top)
		}
		coord_index := engine.random_below(len(available))
		jumbled := available[coord_index]
		unordered_remove(&available, coord_index)

		final_color := engine.gradient_sample(sampler, spectrum[:], initial_coords[id])
		s.jumbled_coords[i] = jumbled
		s.explosion_targets[i] = target
		s.final_colors[i] = final_color
		explosion_steps[i] = max(
			engine.round_to_int(
				engine.line_length(jumbled, target, true) / s.config.explosion_speed,
			),
			1,
		)
		reassembly_steps[i] = max(
			engine.round_to_int(
				engine.line_length(target, initial_coords[id], true) / s.config.reassembly_speed,
			),
			1,
		)
		s.explosion_max_steps = max(s.explosion_max_steps, explosion_steps[i])
		s.reassembly_limit = max(s.reassembly_limit, reassembly_steps[i])
		current_coords[id] = jumbled
		if s.color_handling == .Dynamic {
			style := engine.get_initial_appearance(e, engine.Particle_Id(id))
			if style.colors.fg == nil do s.reassembly_limit = max(s.reassembly_limit, 42)
			engine.set_foreground(
				e,
				id,
				style.colors.fg != nil ? style.colors.fg.? : engine.Color{0x80, 0x80, 0x80},
			)
			engine.set_background(e, id, style.colors.bg)
		} else {
			engine.set_foreground(e, id, final_color)
		}
		visible_flags[id] += {.Visible}
	}
	s.explosion_steps, s.explosion_slots = engine.group_values(explosion_steps)
	s.explosion_factors = make([dynamic]f64, len(s.explosion_steps))
	s.reassembly_steps, s.reassembly_slots = engine.group_values(reassembly_steps)
	s.reassembly_factors = make([dynamic]f64, len(s.reassembly_steps))
	s.phase = .Rumble
	s.rumble_delay = 18
}

unstable_next :: proc(s: ^Unstable_State, e: ^engine.Engine) -> bool #no_bounds_check {
	initial_coords := e.particles.initial_coord

	for {
		switch s.phase {
		case .Rumble:
			if s.phase_tick == 150 {
				s.phase = .Explosion
				s.phase_tick = 0
				continue
			}
			// Compute the final position before publishing this frame.
			jitter := s.phase_tick > 30 && s.phase_tick % s.rumble_delay == 0
			row_offset, column_offset := 0, 0
			if jitter {
				row_offset = engine.random_range(-1, 2)
				column_offset = engine.random_range(-1, 2)
			}
			color_step := min(s.phase_tick / 10, 12)
			color_changed := s.phase_tick <= 120 && s.phase_tick % 10 == 0
			offset := engine.coord(column_offset, row_offset)
			position_changed := offset != s.rumble_offset
			s.rumble_offset = offset
			if position_changed || color_changed {
				for id, i in s.characters {
					if position_changed {
						p := s.jumbled_coords[i]
						engine.set_particle(
							e,
							id,
							engine.coord(p.column + column_offset, p.row + row_offset),
						)
					}
					if !color_changed do continue
					appearance := engine.get_appearance(e, id)
					if s.color_handling == .Dynamic {
						style := engine.get_initial_appearance(e, engine.Particle_Id(id))
						start :=
							style.colors.fg != nil ? style.colors.fg.? : engine.Color{0x80, 0x80, 0x80}
						appearance.colors.fg = engine.gradient_between_step(
							start,
							s.config.unstable_color,
							12,
							color_step,
						)
						if bg, ok := style.colors.bg.?; ok {
							appearance.colors.bg = engine.gradient_between_step(
								bg,
								s.config.unstable_color,
								12,
								color_step,
							)
						} else {
							appearance.colors.bg = nil
						}
					} else {
						appearance.colors.fg = engine.gradient_between_step(
							s.final_colors[i],
							s.config.unstable_color,
							12,
							color_step,
						)
					}
					engine.set_appearance(e, id, appearance)
				}
			}
			if jitter {
				s.rumble_delay = max(s.rumble_delay - 1, 1)
			}
			s.phase_tick += 1
			return true

		case .Explosion:
			if s.phase_tick == s.explosion_max_steps {
				s.phase = .Explosion_Hold
				s.phase_tick = 0
				continue
			}
			for steps, slot in s.explosion_steps {
				if s.phase_tick < steps {
					s.explosion_factors[slot] = ease.ease(
						s.config.explosion_ease,
						f64(s.phase_tick + 1) / f64(steps),
					)
				}
			}
			write := 0
			for i in s.active_indexes {
				id := s.characters[i]
				slot := s.explosion_slots[i]
				steps := s.explosion_steps[slot]
				position := engine.coord_on_line(
					s.jumbled_coords[i],
					s.explosion_targets[i],
					s.explosion_factors[slot],
				)
				engine.set_particle(e, id, position)
				if s.phase_tick + 1 < steps {
					s.active_indexes[write] = i
					write += 1
				}
			}
			resize(&s.active_indexes, write)
			s.phase_tick += 1
			return true

		case .Explosion_Hold:
			if s.phase_tick == 30 {
				s.phase = .Reassembly
				s.phase_tick = 0
				resize(&s.active_indexes, len(s.characters))
				for &index, i in s.active_indexes do index = i
				continue
			}
			s.phase_tick += 1
			return true

		case .Reassembly:
			// 13 gradient entries at three frames each. Motion and color settle
			// together, exactly as the old path + scene combination did.
			if s.phase_tick == s.reassembly_limit do return false
			color_step := min(s.phase_tick / 3, 12)
			color_changed := s.phase_tick <= 39 && s.phase_tick % 3 == 0
			last_color_tick := 39 if s.color_handling == .Dynamic else 36
			for steps, slot in s.reassembly_steps {
				if s.phase_tick < steps {
					s.reassembly_factors[slot] = ease.ease(
						s.config.reassembly_ease,
						f64(s.phase_tick + 1) / f64(steps),
					)
				}
			}
			write := 0
			for i in s.active_indexes {
				id := s.characters[i]
				slot := s.reassembly_slots[i]
				steps := s.reassembly_steps[slot]
				if s.phase_tick + 1 < steps || s.phase_tick < last_color_tick {
					s.active_indexes[write] = i
					write += 1
				}
				if s.phase_tick < steps {
					position := engine.coord_on_line(
						s.explosion_targets[i],
						initial_coords[id],
						s.reassembly_factors[slot],
					)
					engine.set_particle(e, id, position)
				}
				if !color_changed do continue
				appearance := engine.get_appearance(e, id)
				if s.color_handling == .Dynamic {
					style := engine.get_initial_appearance(e, engine.Particle_Id(id))
					if style.colors.fg == nil && s.phase_tick >= 39 {
						appearance.colors.fg = nil
					} else if fg, ok := style.colors.fg.?; ok {
						appearance.colors.fg = engine.gradient_between_step(
							s.config.unstable_color,
							fg,
							12,
							color_step,
						)
					} else {
						appearance.colors.fg = engine.gradient_between_step(
							s.config.unstable_color,
							engine.Color{0x80, 0x80, 0x80},
							12,
							color_step,
						)
					}
					if bg, ok := style.colors.bg.?; ok {
						appearance.colors.bg = engine.gradient_between_step(
							s.config.unstable_color,
							bg,
							12,
							color_step,
						)
					} else {
						appearance.colors.bg = nil
					}
				} else {
					appearance.colors.fg = engine.gradient_between_step(
						s.config.unstable_color,
						s.final_colors[i],
						12,
						color_step,
					)
				}
				engine.set_appearance(e, id, appearance)
			}
			resize(&s.active_indexes, write)
			s.phase_tick += 1
			return true
		}
	}
}
