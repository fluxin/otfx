package effects

import "../engine"

import "core:fmt"
import "core:math/rand"

Binarypath_Config :: struct {
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
	binary_colors:            [dynamic]engine.Color,
	movement_speed:           f64,
	active_binary_groups:     f64,
}

binarypath_config_default :: proc() -> Binarypath_Config {
	cfg := Binarypath_Config {
		final_gradient_direction = .Radial,
		movement_speed           = 1,
		active_binary_groups     = 0.08,
	}
	append(
		&cfg.final_gradient_stops,
		engine.Color{0x00, 0xD5, 0x00},
		engine.Color{0x00, 0x75, 0x00},
	)
	append(&cfg.final_gradient_steps, 12)
	append(
		&cfg.binary_colors,
		..[]engine.Color {
			engine.Color{0x04, 0x4E, 0x29},
			engine.Color{0x15, 0x7E, 0x38},
			engine.Color{0x45, 0xBF, 0x55},
			engine.Color{0x95, 0xED, 0x87},
		},
	)
	return cfg
}

binarypath_parse :: proc(cfg: ^Binarypath_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case "--binary-colors":
			if !parse_colors_flag(&cfg.binary_colors, args, &i, value, has_value) do return false
		case "--movement-speed":
			if !parse_float_flag(&cfg.movement_speed, args, &i, value, has_value) || cfg.movement_speed <= 0 do return false
		case "--active-binary-groups":
			if !parse_float_flag(&cfg.active_binary_groups, args, &i, value, has_value) || cfg.active_binary_groups < 0 || cfg.active_binary_groups > 1 do return false
		case:
			fmt.eprintln("Error: unknown binarypath option: ", name)
			return false
		}
	}
	return true
}

Binarypath_Rep_State :: enum u8 {
	Pending,
	Travel,
	Collapse,
	Ready,
}

// A source glyph owns exactly eight bit glyphs. The outer arrays are SoA
// columns keyed by source-glyph index; bit ids are a flat index*8 + bit row.
// This replaces the Rust port's per-glyph paths, scenes, callbacks, maps, and
// vector-of-vector ownership graph with direct state evaluation.
Binarypath_State :: struct {
	config:             Binarypath_Config,
	characters:         [dynamic]engine.Particle_Id,
	bit_ids:            [dynamic]engine.Particle_Id,
	final_colors:       [dynamic]engine.Color,
	final_colors_by_id: [dynamic]engine.Color,
	bit_colors:         [dynamic]engine.Color,
	origins:            [dynamic]engine.Coord,
	turns:              [dynamic]engine.Coord,
	first_lengths:      [dynamic]f64,
	total_lengths:      [dynamic]f64,
	travel_steps:       [dynamic]int,
	codes:              [dynamic]u32,
	starts:             [dynamic]int,
	states:             [dynamic]Binarypath_Rep_State,
	pending:            [dynamic]int,
	active:             [dynamic]int,
	final_wipe:         engine.Particle_Groups,
	wipe_group:         int,
	max_active:         int,
	tick:               int,
	wiping:             bool,
	color_handling:     engine.Existing_Color_Handling,
}

binarypath_build :: proc(s: ^Binarypath_State, e: ^engine.Engine) {
	s.color_handling = e.cfg.existing_color_handling
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
	s.final_wipe = engine.get_particles_grouped(
		query,
		engine.PARTICLE_FILTER_INPUT,
		.Diagonal_TR2BL,
	)
	n := len(s.characters)
	s.final_colors = make([dynamic]engine.Color, n)
	s.final_colors_by_id = make([dynamic]engine.Color, len(e.particles))
	s.bit_ids = make([dynamic]engine.Particle_Id, n * 8)
	s.bit_colors = make([dynamic]engine.Color, n * 8)
	s.origins = make([dynamic]engine.Coord, n)
	s.turns = make([dynamic]engine.Coord, n)
	s.first_lengths = make([dynamic]f64, n)
	s.total_lengths = make([dynamic]f64, n)
	s.travel_steps = make([dynamic]int, n)
	s.codes = make([dynamic]u32, n)
	s.starts = make([dynamic]int, n)
	s.states = make([dynamic]Binarypath_Rep_State, n)
	s.pending = make([dynamic]int, n)

	initial_coords := e.particles.initial_coord
	visible_flags := e.particles.flags
	for id, i in s.characters {
		target := initial_coords[id]
		s.final_colors[i] = engine.gradient_sample(sampler, spectrum[:], target)
		s.final_colors_by_id[id] = s.final_colors[i]
		visible_flags[id] -= {.Visible}
		origin := engine.canvas_random_coord(e.canvas, true, false)
		turn :=
			rand.int_max(2) == 0 ? engine.coord(origin.column, target.row) : engine.coord(target.column, origin.row)
		first := engine.line_length(origin, turn, true)
		total := first + engine.line_length(turn, target, true)
		s.origins[i], s.turns[i] = origin, turn
		s.first_lengths[i], s.total_lengths[i] = first, total
		s.travel_steps[i] = max(engine.round_to_int(total / s.config.movement_speed), 1)
		s.starts[i] = -1
		s.pending[i] = i
		// ttfx formats the source Unicode code point as eight binary digits.
		r := e.particles.initial_symbol[engine.Particle_Id(id)]
		s.codes[i] = u32(r)
	}
	// No character-storage column is held across add_particle: it can grow and
	// relocate each SoA field. The prep pass above owns all source data needed
	// to create the virtual bit rows below.
	plain := engine.prepare_appearance(e, engine.Appearance{})
	characters := engine.particle_batch(e, 8 * n)
	for i in 0 ..< n {
		for bit in 0 ..< 8 {
			bit_id := engine.add_particle(
				&characters,
				((s.codes[i] >> u32(7 - bit)) & 1) == 0 ? '0' : '1',
				plain,
				s.origins[i],
			)
			color := s.config.binary_colors[rand.int_max(len(s.config.binary_colors))]
			s.bit_ids[i * 8 + bit] = bit_id
			s.bit_colors[i * 8 + bit] = color
			e.particles.flags[bit_id] -= {.Visible}
			e.particles.layer[bit_id] = 1
			engine.set_foreground(e, bit_id, color)
		}
	}
	s.max_active = max(engine.round_to_int(s.config.active_binary_groups * f64(n)), 1)
	reserve(&s.active, min(n, s.max_active))
}

binarypath_coord_at :: proc(s: ^Binarypath_State, e: ^engine.Engine, i, age: int) -> engine.Coord {
	steps := s.travel_steps[i]
	travelled := min(f64(age + 1) / f64(steps), 1) * s.total_lengths[i]
	if travelled <= s.first_lengths[i] {
		t := s.first_lengths[i] == 0 ? 1 : travelled / s.first_lengths[i]
		return engine.coord_on_line(s.origins[i], s.turns[i], t)
	}
	second := s.total_lengths[i] - s.first_lengths[i]
	t := second == 0 ? 1 : (travelled - s.first_lengths[i]) / second
	return engine.coord_on_line(s.turns[i], e.particles.initial_coord[s.characters[i]], t)
}

binarypath_next :: proc(s: ^Binarypath_State, e: ^engine.Engine) -> bool {
	if s.wiping {
		groups := len(s.final_wipe.spans)
		if s.wipe_group >= groups do return false


		visible_flags := e.particles.flags
		for _ in 0 ..< 2 {
			if s.wipe_group == groups do break
			for id in engine.group_members(s.final_wipe, s.wipe_group) {
				engine.set_symbol(e, id, e.particles.initial_symbol[engine.Particle_Id(id)])
				if s.color_handling == .Dynamic {
					appearance := engine.get_appearance(e, id)
					engine.dynamic_apply_input_colors(
						&appearance,
						engine.get_initial_appearance(e, engine.Particle_Id(id)),
					)
					engine.set_appearance(e, id, appearance)
				} else {
					engine.set_foreground(e, id, s.final_colors_by_id[id])
				}
				engine.set_particle(e, id, engine.Visible(true))
			}
			s.wipe_group += 1
		}
		return true
	}

	for len(s.active) < s.max_active && len(s.pending) > 0 {
		pending_index := rand.int_max(len(s.pending))
		rep := s.pending[pending_index]
		last := len(s.pending) - 1
		s.pending[pending_index] = s.pending[last]
		resize(&s.pending, last)
		s.states[rep] = .Travel
		s.starts[rep] = s.tick
		append(&s.active, rep)
	}

	visible_flags := e.particles.flags


	any_collapse := false
	write := 0
	for rep in s.active {
		age := s.tick - s.starts[rep]
		if age <= s.travel_steps[rep] + 7 {
			for bit in 0 ..< 8 {
				bit_age := age - bit
				if bit_age < 0 do continue
				id := s.bit_ids[rep * 8 + bit]
				engine.set_particle(
					e,
					id,
					coord = binarypath_coord_at(s, e, rep, bit_age),
					visible = true,
					layer = e.particles[id].layer,
				)
			}
			s.active[write] = rep
			write += 1
		} else {
			for bit in 0 ..< 8 {
				engine.set_particle(e, s.bit_ids[rep * 8 + bit], engine.Visible(false))
			}
			s.states[rep] = .Collapse
			s.starts[rep] = s.tick
			id := s.characters[rep]
			engine.set_symbol(e, id, e.particles.initial_symbol[engine.Particle_Id(id)])
			engine.set_particle(e, id, engine.Visible(true))
		}
	}
	resize(&s.active, write)

	for id, i in s.characters {
		if s.states[i] != .Collapse do continue
		age := s.tick - s.starts[i]
		if age < 21 {
			if s.color_handling == .Dynamic {
				style := engine.get_initial_appearance(e, engine.Particle_Id(id))
				appearance := engine.get_appearance(e, id)
				engine.dynamic_gradient_to_dimmed_input(
					&appearance,
					engine.Color{0xFF, 0xFF, 0xFF},
					style,
					0.5,
					6,
					age / 3,
				)
				engine.set_appearance(e, id, appearance)
			} else {
				dim := engine.adjust_color_brightness(s.final_colors[i], 0.5)
				engine.set_foreground(
					e,
					id,
					engine.gradient_between_step(engine.Color{0xFF, 0xFF, 0xFF}, dim, 6, age / 3),
				)
			}
			any_collapse = true
		} else {
			// Only the colour animation ends here; the character stays on
			// screen. Hiding it again would leave nothing accumulating, so the
			// whole logo would appear at once during the final wipe instead of
			// filling in as each representation lands.
			s.states[i] = .Ready
		}
	}
	if len(s.pending) == 0 && len(s.active) == 0 && !any_collapse {
		s.wiping = true
		return binarypath_next(s, e)
	}
	s.tick += 1
	return true
}
