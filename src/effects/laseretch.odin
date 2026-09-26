package effects

import engine "../engine"

import "core:fmt"
import "core:math/ease"
import "core:math/rand"
import "core:slice"

Laseretch_Config :: struct {
	etch_pattern:             Maybe(engine.Particle_Group), // nil = algorithm order
	etch_speed:               int,
	etch_delay:               int,
	cool_gradient_stops:      [dynamic]engine.Color,
	laser_gradient_stops:     [dynamic]engine.Color,
	spark_gradient_stops:     [dynamic]engine.Color,
	spark_cooling_frames:     int,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_frames:    int,
	final_gradient_direction: engine.Gradient_Direction,
}

laseretch_config_default :: proc() -> Laseretch_Config {
	cfg := Laseretch_Config {
		etch_speed               = 1,
		etch_delay               = 1,
		spark_cooling_frames     = 7,
		final_gradient_frames    = 4,
		final_gradient_direction = .Vertical,
	}
	append(
		&cfg.cool_gradient_stops,
		engine.Color{0xFF, 0xE6, 0x80},
		engine.Color{0xFF, 0x7B, 0x00},
	)
	append(
		&cfg.laser_gradient_stops,
		engine.Color{0xFF, 0xFF, 0xFF},
		engine.Color{0x37, 0x6C, 0xFF},
	)
	append(
		&cfg.spark_gradient_stops,
		engine.Color{0xFF, 0xFF, 0xFF},
		engine.Color{0xFF, 0xE6, 0x80},
		engine.Color{0xFF, 0x7B, 0x00},
		engine.Color{0x1A, 0x09, 0x00},
	)
	append(
		&cfg.final_gradient_stops,
		engine.Color{0x8A, 0x00, 0x8A},
		engine.Color{0x00, 0xD1, 0xFF},
		engine.Color{0xFF, 0xFF, 0xFF},
	)
	append(&cfg.final_gradient_steps, 8)
	return cfg
}

laseretch_parse :: proc(cfg: ^Laseretch_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--etch-pattern":
			v, ok := opt_value(args, &i, value, has_value)
			if !ok do return false
			if v == "algorithm" {
				cfg.etch_pattern = nil
			} else {
				group, valid := engine.group_parse(v)
				if !valid do return false
				cfg.etch_pattern = group
			}
		case "--etch-speed":
			if !parse_int_flag(&cfg.etch_speed, args, &i, value, has_value) || cfg.etch_speed <= 0 do return false
		case "--etch-delay":
			if !parse_int_flag(&cfg.etch_delay, args, &i, value, has_value, minimum = 0) || cfg.etch_delay < 0 do return false
		case "--cool-gradient-stops":
			if !parse_colors_flag(&cfg.cool_gradient_stops, args, &i, value, has_value) do return false
		case "--laser-gradient-stops":
			if !parse_colors_flag(&cfg.laser_gradient_stops, args, &i, value, has_value) do return false
		case "--spark-gradient-stops":
			if !parse_colors_flag(&cfg.spark_gradient_stops, args, &i, value, has_value) do return false
		case "--spark-cooling-frames":
			if !parse_int_flag(&cfg.spark_cooling_frames, args, &i, value, has_value) || cfg.spark_cooling_frames <= 0 do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-frames":
			if !parse_int_flag(&cfg.final_gradient_frames, args, &i, value, has_value) || cfg.final_gradient_frames <= 0 do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown laseretch option: ", name)
			return false
		}
	}
	return true
}

// Beam ids follow canvas height. Spark ids follow input count: every source
// glyph emits at most one spark, so this is the exact reachable upper bound,
// including an arbitrary --etch-speed that emits every glyph in one frame.
Laseretch_State :: struct {
	config:         Laseretch_Config,
	characters:     [dynamic]engine.Particle_Id,
	index_by_id:    [dynamic]int,
	final_colors:   [dynamic]engine.Color,
	source_starts:  [dynamic]int,
	active_sources: [dynamic]int,
	pending:        [dynamic]engine.Particle_Id,
	pending_head:   int,
	cool_spectrum:  [dynamic]engine.Color,
	laser_spectrum: [dynamic]engine.Color,
	spark_spectrum: [dynamic]engine.Color,
	beam_ids:       [dynamic]engine.Particle_Id,
	laser_position: engine.Coord,
	spark_ids:      [dynamic]engine.Particle_Id,
	spark_starts:   [dynamic]int,
	spark_origins:  [dynamic]engine.Coord,
	spark_controls: [dynamic]engine.Coord,
	spark_targets:  [dynamic]engine.Coord,
	spark_steps:    [dynamic]int,
	active_sparks:  [dynamic]int,
	next_spark:     int,
	delay:          int,
	tick:           int,
	color_handling: engine.Existing_Color_Handling,
}

// First visits of a randomized depth-first walk. Fill cells bridge gaps in the
// text but are not etched. Only the resulting target order survives build.
laseretch_order :: proc(s: ^Laseretch_State, e: ^engine.Engine) {
	query := engine.Particle_Query {
		e.particle_sets,
		e.particles.initial_coord[:len(e.particles)],
		e.canvas,
	}
	cells := engine.get_particles(query, {.Input, .Inner_Fill}, .Top_Bottom_Left_Right)
	defer delete(cells)
	n := len(cells)
	if n == 0 do return
	visited := make([]bool, n, context.temp_allocator)
	stack := make([dynamic]int, 0, n, context.temp_allocator)
	width := e.canvas.text_width
	offsets := [4]int{-width, 1, width, -1}
	current := rand.int_max(n)
	for {
		if !visited[current] {
			visited[current] = true
			append(&stack, current)
			id := cells[current]
			if !e.particles.is_fill[id] do append(&s.pending, id)
		}
		neighbors: [dynamic; 4]int
		column := current % width
		for offset, direction in offsets {
			next := current + offset
			if next < 0 ||
			   next >= n ||
			   (direction == 1 && column == width - 1) ||
			   (direction == 3 && column == 0) ||
			   visited[next] {
				continue
			}
			append(&neighbors, next)
		}
		if len(neighbors) > 0 {
			current = neighbors[rand.int_max(len(neighbors))]
		} else {
			pop(&stack)
			if len(stack) == 0 do break
			current = stack[len(stack) - 1]
		}
	}
}

laseretch_build :: proc(s: ^Laseretch_State, e: ^engine.Engine) {
	s.color_handling = e.cfg.existing_color_handling
	final_spectrum := engine.gradient_make(
		s.config.final_gradient_stops[:],
		s.config.final_gradient_steps[:],
		false,
	)
	defer delete(final_spectrum[:])
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
	reserve(&s.pending, len(s.characters))
	if group, has_group := s.config.etch_pattern.?; has_group {
		grouped := engine.get_particles_grouped(query, engine.PARTICLE_FILTER_INPUT, group)
		defer engine.groups_delete(&grouped)
		for _, i in grouped.spans {
			if i % 2 != 0 do slice.reverse(engine.group_members(grouped, i))
		}
		append(&s.pending, ..grouped.members[:])
	} else {
		laseretch_order(s, e)
	}
	n := len(s.characters)
	reserve(&s.active_sources, n)
	reserve(&s.active_sparks, n)
	s.index_by_id = make([dynamic]int, len(e.particles))
	s.final_colors = make([dynamic]engine.Color, n)
	s.source_starts = make([dynamic]int, n)
	s.cool_spectrum = engine.gradient_make(s.config.cool_gradient_stops[:], []int{8}, false)
	s.laser_spectrum = engine.gradient_make(s.config.laser_gradient_stops[:], []int{6}, true)
	s.spark_spectrum = engine.gradient_make(s.config.spark_gradient_stops[:], []int{3, 8}, false)

	initial_coords := e.particles.initial_coord
	visible := e.particles.is_visible
	for id, i in s.characters {
		s.index_by_id[id] = i
		s.final_colors[i] = engine.gradient_sample(
			final_sampler,
			final_spectrum[:],
			initial_coords[id],
		)
		s.source_starts[i] = -1
		visible[id] = false
	}

	// Create all generated rows after no storage column is borrowed. There is one
	// spark row per source glyph, the exact upper bound for this one-strike-per-
	// glyph effect; branch wrap remains free of hot-path division.
	characters := engine.particle_batch(e, e.canvas.top + 1 + n)
	for row in 0 ..= e.canvas.top {
		symbol := row == 0 ? "*" : "/"
		id := engine.add_particle(&characters, symbol, engine.coord(0, 0))
		e.particles.is_visible[id] = true
		e.particles.layer[id] = 2
		append(&s.beam_ids, id)
	}
	for i in 0 ..< n {
		symbols := [3]string{".", ",", "*"}
		id := engine.add_particle(
			&characters,
			symbols[rand.int_max(len(symbols))],
			engine.coord(0, 0),
		)
		e.particles.is_visible[id] = false
		e.particles.layer[id] = 2
		append(&s.spark_ids, id)
		append(&s.spark_starts, -1)
		append(&s.spark_origins, engine.coord(0, 0))
		append(&s.spark_controls, engine.coord(0, 0))
		append(&s.spark_targets, engine.coord(0, 0))
		append(&s.spark_steps, 1)
	}
}

laseretch_spawn_spark :: proc(s: ^Laseretch_State, e: ^engine.Engine, origin: engine.Coord) {
	i := s.next_spark
	s.next_spark += 1
	if s.next_spark == len(s.spark_ids) do s.next_spark = 0
	target := engine.coord(rand.int_range(origin.column - 20, origin.column + 21), e.canvas.bottom)
	control := engine.coord(target.column, origin.row + rand.int_range(-10, 21))
	s.spark_starts[i] = s.tick
	s.spark_origins[i], s.spark_controls[i], s.spark_targets[i] = origin, control, target
	s.spark_steps[i] = max(
		engine.round_half_even(engine.quadratic_bezier_length(origin, control, target) / 0.3),
		1,
	)
	append(&s.active_sparks, i)
	engine.set_particle(e, s.spark_ids[i], visible = true)
}

laseretch_next :: proc(s: ^Laseretch_State, e: ^engine.Engine) -> bool {
	if s.pending_head == len(s.pending) &&
	   len(s.active_sources) == 0 &&
	   len(s.active_sparks) == 0 {
		return false
	}

	if s.pending_head < len(s.pending) {
		if s.delay == 0 {
			for _ in 0 ..< s.config.etch_speed {
				if s.pending_head == len(s.pending) do break
				id := s.pending[s.pending_head]
				s.pending_head += 1
				i := s.index_by_id[id]
				s.source_starts[i] = s.tick
				append(&s.active_sources, i)
				s.laser_position = e.particles.initial_coord[id]
				engine.set_particle(e, id, visible = true)
				laseretch_spawn_spark(s, e, s.laser_position)
			}
			s.delay = s.config.etch_delay
		} else {
			s.delay -= 1
		}
	}

	// Only the short cooling tail needs updates. Completed source glyphs retain
	// their final visual, so scanning the full input every frame is wasted work.
	source_write := 0
	for i in s.active_sources {
		id := s.characters[i]
		start := s.source_starts[i]
		age := s.tick - start
		source_lifetime := 3 + (len(s.cool_spectrum) + 8) * 3
		if s.color_handling == .Dynamic {
			has_style :=
				engine.get_initial_visual(e, engine.Particle_Id(id)).fg != nil ||
				engine.get_initial_visual(e, engine.Particle_Id(id)).bg != nil
			source_lifetime = 3 + len(s.cool_spectrum) * 3 + (has_style ? 9 : 10) * 3
		}
		if age >= source_lifetime {
			engine.set_symbol(e, id, engine.get_initial_visual(e, engine.Particle_Id(id)).symbol)
			if s.color_handling == .Dynamic {
				visual := engine.get_visual(e, id)
				engine.dynamic_apply_input_colors(
					&visual,
					engine.get_initial_visual(e, engine.Particle_Id(id)),
				)
				engine.set_visual(e, id, visual)
			} else {
				engine.set_foreground(e, id, s.final_colors[i])
			}
			continue
		}
		engine.set_symbol(
			e,
			id,
			age < 3 ? "^" : engine.get_initial_visual(e, engine.Particle_Id(id)).symbol,
		)
		if age < 3 {
			engine.set_foreground(e, id, engine.Color{0xFF, 0xE6, 0x80})
		} else if age < 3 + len(s.cool_spectrum) * 3 {
			engine.set_foreground(e, id, s.cool_spectrum[(age - 3) / 3])
		} else {
			cool_age := age - 3 - len(s.cool_spectrum) * 3
			if s.color_handling == .Dynamic {
				style := engine.get_initial_visual(e, engine.Particle_Id(id))
				if style.fg != nil || style.bg != nil {
					visual := engine.get_visual(e, id)
					engine.dynamic_gradient_to_input(
						&visual,
						s.cool_spectrum[len(s.cool_spectrum) - 1],
						style,
						8,
						min(cool_age / 3, 8),
					)
					engine.set_visual(e, id, visual)
				} else if cool_age < 27 {
					engine.set_foreground(
						e,
						id,
						engine.gradient_between_step(
							s.cool_spectrum[len(s.cool_spectrum) - 1],
							engine.Color{0xFF, 0xFF, 0xFF},
							8,
							cool_age / 3,
						),
					)
					engine.set_background(e, id, nil)
				} else {
					engine.set_foreground(e, id, nil)
					engine.set_background(e, id, nil)
				}
			} else {
				engine.set_foreground(
					e,
					id,
					engine.gradient_between_step(
						s.cool_spectrum[len(s.cool_spectrum) - 1],
						s.final_colors[i],
						8,
						min(1 + cool_age / 3, 8),
					),
				)
			}
		}
		s.active_sources[source_write] = i
		source_write += 1
	}
	resize(&s.active_sources, source_write)

	visible := e.particles.is_visible
	if s.pending_head < len(s.pending) {
		color_index := (s.tick / 3) % len(s.laser_spectrum)
		for id, beam in s.beam_ids {
			engine.set_particle(
				e,
				id,
				coord = engine.coord(s.laser_position.column + beam, s.laser_position.row + beam),
			)
			engine.set_foreground(e, id, s.laser_spectrum[color_index])
			engine.set_particle(e, id, visible = true)
			color_index += 1
			if color_index == len(s.laser_spectrum) do color_index = 0
		}
	} else {
		for id in s.beam_ids {
			engine.set_particle(e, id, visible = false)
		}
	}

	// The backing spark arrays are fixed capacity, while this compact index
	// slice contains only live sparks. It keeps both movement and rendering
	// proportional to live particles rather than input length.
	spark_write := 0
	for i in s.active_sparks {
		id := s.spark_ids[i]
		start := s.spark_starts[i]
		age := s.tick - start
		color_step := age / s.config.spark_cooling_frames
		if color_step >= len(s.spark_spectrum) {
			engine.set_particle(e, id, visible = false)
			s.spark_starts[i] = -1
			continue
		}
		if age < s.spark_steps[i] {
			engine.set_particle(
				e,
				id,
				coord = engine.coord_on_quadratic_bezier(
					s.spark_origins[i],
					s.spark_controls[i],
					s.spark_targets[i],
					ease.ease(.Sine_Out, f64(age + 1) / f64(s.spark_steps[i])),
				),
			)
		}
		engine.set_foreground(e, id, s.spark_spectrum[color_step])
		s.active_sparks[spark_write] = i
		spark_write += 1
	}
	resize(&s.active_sparks, spark_write)

	s.tick += 1
	return true
}
