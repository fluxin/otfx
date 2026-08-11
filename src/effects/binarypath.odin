package effects

import engine "../engine"

import "core:fmt"
import rand "core:math/rand"
import "core:unicode/utf8"

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
	characters:         [dynamic]engine.Char_Id,
	bit_ids:            [dynamic]engine.Char_Id,
	render_ids:         [dynamic]engine.Char_Id,
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
	final_wipe:         engine.Char_Groups,
	wipe_group:         int,
	max_active:         int,
	tick:               int,
	wiping:             bool,
}

binarypath_build :: proc(s: ^Binarypath_State, e: ^engine.Engine) {
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
	query := engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas}
	s.characters = engine.get_characters(query, engine.filter_input(), .Top_Bottom_Left_Right)
	s.final_wipe = engine.get_characters_grouped(query, engine.filter_input(), .Diagonal_TR2BL)
	n := len(s.characters)
	s.final_colors = make([dynamic]engine.Color, n)
	s.final_colors_by_id = make([dynamic]engine.Color, len(e.chars))
	s.bit_ids = make([dynamic]engine.Char_Id, n * 8)
	s.bit_colors = make([dynamic]engine.Color, n * 8)
	s.origins = make([dynamic]engine.Coord, n)
	s.turns = make([dynamic]engine.Coord, n)
	s.first_lengths = make([dynamic]f64, n)
	s.total_lengths = make([dynamic]f64, n)
	s.travel_steps = make([dynamic]int, n)
	s.codes = make([dynamic]u32, n)
	s.starts = make([dynamic]int, n)
	s.states = make([dynamic]Binarypath_Rep_State, n)
	reserve(&s.render_ids, n * 9)
	append(&s.render_ids, ..s.characters[:])

	input_coords := e.chars.input_coord
	input_symbols := e.chars.input_symbol
	visible := e.chars.is_visible
	for id, i in s.characters {
		target := input_coords[id]
		s.final_colors[i] = engine.gradient_sample(sampler, spectrum[:], target)
		s.final_colors_by_id[id] = s.final_colors[i]
		visible[id] = false
		origin := engine.canvas_random_coord(e.canvas, true, false)
		turn :=
			rand.int_max(2) == 0 ? engine.coord(origin.column, target.row) : engine.coord(target.column, origin.row)
		first := engine.line_length(origin, turn, true)
		total := first + engine.line_length(turn, target, true)
		s.origins[i], s.turns[i] = origin, turn
		s.first_lengths[i], s.total_lengths[i] = first, total
		s.travel_steps[i] = max(engine.round_half_even(total / s.config.movement_speed), 1)
		s.starts[i] = -1
		append(&s.pending, i)
		// ttfx formats the source Unicode code point as eight binary digits.
		r, _ := utf8.decode_rune(input_symbols[id])
		s.codes[i] = u32(r)
	}
	// No character-storage column is held across add_character: it can grow and
	// relocate each SoA field. The prep pass above owns all source data needed
	// to create the virtual bit rows below.
	for i in 0 ..< n {
		for bit in 0 ..< 8 {
			symbol := ((s.codes[i] >> u32(7 - bit)) & 1) == 0 ? "0" : "1"
			bit_id := engine.add_character(e, symbol, s.origins[i])
			color := s.config.binary_colors[rand.int_max(len(s.config.binary_colors))]
			s.bit_ids[i * 8 + bit] = bit_id
			s.bit_colors[i * 8 + bit] = color
			e.chars.is_visible[bit_id] = false
			e.chars.layer[bit_id] = 1
			e.chars.visual_fg[bit_id] = color
			append(&s.render_ids, bit_id)
		}
	}
	s.max_active = max(engine.round_half_even(s.config.active_binary_groups * f64(n)), 1)
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
	return engine.coord_on_line(s.turns[i], e.chars.input_coord[s.characters[i]], t)
}

binarypath_next :: proc(s: ^Binarypath_State, e: ^engine.Engine) -> bool {
	if s.wiping {
		groups := engine.group_count(s.final_wipe)
		if s.wipe_group >= groups do return false
		input_symbols := e.chars.input_symbol
		visual_symbols := e.chars.visual_symbol
		visual_fg := e.chars.visual_fg
		visible := e.chars.is_visible
		for _ in 0 ..< 2 {
			if s.wipe_group == groups do break
			for id in engine.group_slice(s.final_wipe, s.wipe_group) {
				visual_symbols[id] = input_symbols[id]
				visual_fg[id] = s.final_colors_by_id[id]
				visible[id] = true
			}
			s.wipe_group += 1
		}
		engine.frame(e, s.render_ids[:])
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

	current_coords := e.chars.current_coord
	visible := e.chars.is_visible
	visual_fg := e.chars.visual_fg
	visual_symbols := e.chars.visual_symbol
	input_symbols := e.chars.input_symbol
	any_collapse := false
	write := 0
	for rep in s.active {
		age := s.tick - s.starts[rep]
		if age <= s.travel_steps[rep] + 7 {
			for bit in 0 ..< 8 {
				bit_age := age - bit
				if bit_age < 0 do continue
				id := s.bit_ids[rep * 8 + bit]
				current_coords[id] = binarypath_coord_at(s, e, rep, bit_age)
				visible[id] = true
			}
			s.active[write] = rep
			write += 1
		} else {
			for bit in 0 ..< 8 do visible[s.bit_ids[rep * 8 + bit]] = false
			s.states[rep] = .Collapse
			s.starts[rep] = s.tick
			id := s.characters[rep]
			visual_symbols[id] = input_symbols[id]
			visible[id] = true
		}
	}
	resize(&s.active, write)

	for id, i in s.characters {
		if s.states[i] != .Collapse do continue
		age := s.tick - s.starts[i]
		if age < 21 {
			dim := engine.adjust_color_brightness(s.final_colors[i], 0.5)
			visual_fg[id] = engine.gradient_between_step(
				engine.Color{0xFF, 0xFF, 0xFF},
				dim,
				6,
				age / 3,
			)
			any_collapse = true
		} else {
			visible[id] = false
			s.states[i] = .Ready
		}
	}
	if len(s.pending) == 0 && len(s.active) == 0 && !any_collapse {
		s.wiping = true
		return binarypath_next(s, e)
	}
	s.tick += 1
	engine.frame(e, s.render_ids[:])
	return true
}
