package effects

import "../engine"

import "core:fmt"

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

// A source glyph owns exactly eight bit glyphs. The outer arrays are SoA
// columns keyed by source-glyph index; bit ids are a flat index*8 + bit row.
// This replaces the Rust port's per-glyph paths, scenes, callbacks, maps, and
// vector-of-vector ownership graph with direct state evaluation.
Binarypath_State :: struct {
	config:         Binarypath_Config,
	characters:     [dynamic]engine.Particle_Id,
	first_bit_id:   engine.Particle_Id,
	collapse_ramp:  engine.Appearance_Ramp,
	style_index:    [dynamic]int,
	final_codes:    [dynamic]engine.Appearance_Id,
	origins:        [dynamic]engine.Coord,
	turns:          [dynamic]engine.Coord,
	first_lengths:  [dynamic]f64,
	total_lengths:  [dynamic]f64,
	travel_steps:   [dynamic]int,
	codes:          [dynamic]u32,
	starts:         [dynamic]int,
	collapsing:     [dynamic]int,
	pending:        [dynamic]int,
	active:         [dynamic]int,
	final_wipe:     engine.Particle_Groups,
	wipe_group:     int,
	max_active:     int,
	tick:           int,
	wiping:         bool,
	color_handling: engine.Existing_Color_Handling,
}

binarypath_build :: proc(s: ^Binarypath_State, e: ^engine.Engine) {
	s.color_handling = e.cfg.existing_color_handling
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
	s.final_wipe = engine.get_particles_grouped(
		query,
		engine.PARTICLE_FILTER_INPUT,
		.Diagonal_TR2BL,
	)
	n := len(s.characters)
	s.final_codes = make([dynamic]engine.Appearance_Id, len(e.particles))
	s.origins = make([dynamic]engine.Coord, n)
	s.turns = make([dynamic]engine.Coord, n)
	s.first_lengths = make([dynamic]f64, n)
	s.total_lengths = make([dynamic]f64, n)
	s.travel_steps = make([dynamic]int, n)
	s.codes = make([dynamic]u32, n)
	s.starts = make([dynamic]int, n)
	s.pending = make([dynamic]int, n)

	target_styles := make([]engine.Appearance, n, context.temp_allocator)
	defer delete(target_styles, context.temp_allocator)
	initial_coords := e.particles.initial_coord
	flags := e.particles.flags
	for id, i in s.characters {
		target := initial_coords[id]
		if s.color_handling == .Dynamic {
			init_style := engine.get_initial_appearance(e, id)
			target_styles[i] = {colors = init_style.colors, bold = init_style.bold}
		} else {
			target_styles[i] = {colors = {fg = engine.gradient_sample(sampler, spectrum[:], target)}}
		}
		flags[id] -= {.Visible}
		origin := engine.canvas_random_coord(e.canvas, true, false)
		turn :=
			engine.random_below(2) == 0 ? engine.coord(origin.column, target.row) : engine.coord(target.column, origin.row)
		first := engine.line_length(origin, turn, true)
		total := first + engine.line_length(turn, target, true)
		s.origins[i], s.turns[i] = origin, turn
		s.first_lengths[i], s.total_lengths[i] = first, total
		s.travel_steps[i] = max(engine.round_to_int(total / s.config.movement_speed), 1)
		s.starts[i] = -1
		s.pending[i] = i
		// ttfx formats the source Unicode code point as eight binary digits.
		s.codes[i] = u32(e.particles.initial_symbol[id])
	}

	unique_styles: [dynamic]engine.Appearance
	unique_styles, s.style_index = engine.group_values(target_styles)
	defer delete(unique_styles)
	tweens := make([]engine.Tween(engine.Appearance), len(unique_styles), context.temp_allocator)
	defer delete(tweens, context.temp_allocator)
	final_row_codes := make([]engine.Appearance_Id, len(unique_styles), context.temp_allocator)
	defer delete(final_row_codes, context.temp_allocator)
	white := engine.Color{0xFF, 0xFF, 0xFF}
	for row_style, row in unique_styles {
		final_row_codes[row] = engine.prepare_appearance(e, row_style)
		dimmed := row_style.colors
		if fg, ok := dimmed.fg.?; ok do dimmed.fg = engine.adjust_color_brightness(fg, 0.5)
		if bg, ok := dimmed.bg.?; ok do dimmed.bg = engine.adjust_color_brightness(bg, 0.5)
		tweens[row] = {
			from = {colors = {white, white}, bold = row_style.bold},
			to   = {colors = dimmed, bold = row_style.bold},
		}
	}
	s.collapse_ramp = engine.ramp_make(e, tweens, 6)
	for id, i in s.characters {
		s.final_codes[id] = final_row_codes[s.style_index[i]]
	}

	palette_len := max(len(s.config.binary_colors), 1)
	binary_codes := make([]engine.Appearance_Id, palette_len, context.temp_allocator)
	defer delete(binary_codes, context.temp_allocator)
	if len(s.config.binary_colors) == 0 {
		binary_codes[0] = engine.prepare_appearance(e, engine.Appearance{})
	} else {
		for color, ci in s.config.binary_colors {
			binary_codes[ci] = engine.prepare_appearance(e, engine.Appearance{colors = {fg = color}})
		}
	}

	// No character-storage column is held across add_particle: it can grow and
	// relocate each SoA field. Bit particles occupy one contiguous ID span.
	s.first_bit_id = engine.Particle_Id(len(e.particles))
	characters := engine.particle_batch(e, 8 * n)
	for i in 0 ..< n {
		for bit in 0 ..< 8 {
			code := binary_codes[engine.random_below(palette_len)]
			bit_id := engine.add_particle(
				&characters,
				((s.codes[i] >> u32(7 - bit)) & 1) == 0 ? '0' : '1',
				code,
				s.origins[i],
			)
			e.particles.flags[bit_id] -= {.Visible}
			e.particles.layer[bit_id] = 1
		}
	}
	s.max_active = max(engine.round_to_int(s.config.active_binary_groups * f64(n)), 1)
	reserve(&s.active, min(n, s.max_active))
	reserve(&s.collapsing, n)
}

binarypath_coord_at :: proc(s: ^Binarypath_State, e: ^engine.Engine, i, age: int) -> engine.Coord #no_bounds_check {
	steps := s.travel_steps[i]
	travelled := min(f64(age + 1) / f64(steps), 1) * s.total_lengths[i]
	if travelled <= s.first_lengths[i] {
		t := s.first_lengths[i] == 0 ? 1 : travelled / s.first_lengths[i]
		return engine.tween(s.origins[i], s.turns[i], t)
	}
	second := s.total_lengths[i] - s.first_lengths[i]
	t := second == 0 ? 1 : (travelled - s.first_lengths[i]) / second
	return engine.tween(s.turns[i], e.particles.initial_coord[s.characters[i]], t)
}

binarypath_next :: proc(s: ^Binarypath_State, e: ^engine.Engine) -> bool #no_bounds_check {
	if s.wiping {
		groups := len(s.final_wipe.spans)
		if s.wipe_group >= groups do return false
		for _ in 0 ..< 2 {
			if s.wipe_group == groups do break
			for id in engine.group_members(s.final_wipe, s.wipe_group) {
				engine.set_symbol(e, id, e.particles.initial_symbol[id])
				engine.set_appearance(e, id, s.final_codes[id])
				engine.set_particle(e, id, engine.Visible(true))
			}
			s.wipe_group += 1
		}
		return true
	}

	for len(s.active) < s.max_active && len(s.pending) > 0 {
		pending_index := engine.random_below(len(s.pending))
		rep := s.pending[pending_index]
		last := len(s.pending) - 1
		s.pending[pending_index] = s.pending[last]
		resize(&s.pending, last)
		s.starts[rep] = s.tick
		append(&s.active, rep)
	}

	write := 0
	for rep in s.active {
		age := s.tick - s.starts[rep]
		steps := s.travel_steps[rep]
		base_bit := s.first_bit_id + engine.Particle_Id(rep * 8)
		if age <= steps + 7 {
			// Bit k at age a samples the path at a - k, which is where bit k - 1
			// was published on the previous tick. Snapshot those coordinates
			// before any write, so only the leading bit evaluates the path.
			trail: [8]engine.Coord
			trail[0] =
				age < steps ? binarypath_coord_at(s, e, rep, age) : e.particles.initial_coord[s.characters[rep]]
			for bit in 1 ..< 8 do trail[bit] = e.particles.current_coord[base_bit + engine.Particle_Id(bit - 1)]
			for bit in 0 ..< 8 {
				if age < bit do break
				id := base_bit + engine.Particle_Id(bit)
				if age == bit {
					engine.set_particle(e, id, trail[bit], true, 1)
				} else {
					engine.set_position(e, id, trail[bit])
				}
			}
			s.active[write] = rep
			write += 1
		} else {
			for bit in 0 ..< 8 {
				engine.set_particle(e, base_bit + engine.Particle_Id(bit), engine.Visible(false))
			}
			append(&s.collapsing, rep)
			s.starts[rep] = s.tick
			id := s.characters[rep]
			engine.set_symbol(e, id, e.particles.initial_symbol[id])
			engine.set_particle(e, id, engine.Visible(true))
		}
	}
	resize(&s.active, write)

	collapse_write := 0
	for i in s.collapsing {
		id := s.characters[i]
		age := s.tick - s.starts[i]
		if age < 21 {
			s.collapsing[collapse_write] = i
			collapse_write += 1
			if age % 3 != 0 do continue
			engine.set_appearance(e, id, engine.ramp_code(s.collapse_ramp, s.style_index[i], age / 3))
		}
	}
	resize(&s.collapsing, collapse_write)
	if len(s.pending) == 0 && len(s.active) == 0 && len(s.collapsing) == 0 {
		s.wiping = true
		return binarypath_next(s, e)
	}
	s.tick += 1
	return true
}
