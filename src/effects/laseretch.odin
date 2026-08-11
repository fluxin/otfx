package effects

import engine "../engine"

import "core:fmt"
import ease "core:math/ease"
import rand "core:math/rand"

Laseretch_Config :: struct {
	etch_pattern:             Maybe(engine.Character_Group), // nil = algorithm order
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
			if !parse_int_flag(&cfg.etch_delay, args, &i, value, has_value) || cfg.etch_delay < 0 do return false
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
	config:           Laseretch_Config,
	characters:       [dynamic]engine.Char_Id,
	index_by_id:      [dynamic]int,
	render_ids:       [dynamic]engine.Char_Id,
	final_colors:     [dynamic]engine.Color,
	source_starts:    [dynamic]int,
	active_sources:   [dynamic]int,
	pending:          [dynamic]engine.Char_Id,
	pending_head:     int,
	cool_spectrum:    [dynamic]engine.Color,
	laser_spectrum:   [dynamic]engine.Color,
	spark_spectrum:   [dynamic]engine.Color,
	beam_ids:         [dynamic]engine.Char_Id,
	beam_color_index: int,
	laser_position:   engine.Coord,
	spark_ids:        [dynamic]engine.Char_Id,
	spark_starts:     [dynamic]int,
	spark_origins:    [dynamic]engine.Coord,
	spark_controls:   [dynamic]engine.Coord,
	spark_targets:    [dynamic]engine.Coord,
	spark_steps:      [dynamic]int,
	active_sparks:    [dynamic]int,
	next_spark:       int,
	delay:            int,
	tick:             int,
}

laseretch_build :: proc(s: ^Laseretch_State, e: ^engine.Engine) {
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
	query := engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas}
	s.characters = engine.get_characters(query, engine.CHAR_FILTER_INPUT, .Top_Bottom_Left_Right)
	if group, has_group := s.config.etch_pattern.?; has_group {
		grouped := engine.get_characters_grouped(query, engine.CHAR_FILTER_INPUT, group)
		defer engine.groups_delete(&grouped)
		append(&s.pending, ..grouped.members[:])
	} else {
		append(&s.pending, ..s.characters[:])
		rand.shuffle(s.pending[:])
	}
	n := len(s.characters)
	s.index_by_id = make([dynamic]int, len(e.chars))
	s.final_colors = make([dynamic]engine.Color, n)
	s.source_starts = make([dynamic]int, n)
	s.cool_spectrum = engine.gradient_make(s.config.cool_gradient_stops[:], []int{8}, false)
	s.laser_spectrum = engine.gradient_make(s.config.laser_gradient_stops[:], []int{6}, true)
	s.spark_spectrum = engine.gradient_make(s.config.spark_gradient_stops[:], []int{3, 8}, false)

	input_coords := e.chars.input_coord
	visible := e.chars.is_visible
	for id, i in s.characters {
		s.index_by_id[id] = i
		s.final_colors[i] = engine.gradient_sample(
			final_sampler,
			final_spectrum[:],
			input_coords[id],
		)
		s.source_starts[i] = -1
		visible[id] = false
	}
	// The render prefix is permanent: source glyphs and the beam can remain
	// visible. Active spark ids are appended as a compact suffix each frame.
	reserve(&s.render_ids, n * 2 + e.canvas.top + 1)
	append(&s.render_ids, ..s.characters[:])

	// Create all generated rows after no storage column is borrowed. There is one
	// spark row per source glyph, the exact upper bound for this one-strike-per-
	// glyph effect; branch wrap remains free of hot-path division.
	for row in 0 ..= e.canvas.top {
		symbol := row == 0 ? "*" : "/"
		id := engine.add_character(e, symbol, engine.coord(0, 0))
		e.chars.is_visible[id] = true
		e.chars.layer[id] = 2
		append(&s.beam_ids, id)
		append(&s.render_ids, id)
	}
	for i in 0 ..< n {
		id := engine.add_character(e, "*", engine.coord(0, 0))
		e.chars.is_visible[id] = false
		e.chars.layer[id] = 2
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
	e.chars.is_visible[s.spark_ids[i]] = true
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
				s.laser_position = e.chars.input_coord[id]
				e.chars.is_visible[id] = true
				laseretch_spawn_spark(s, e, s.laser_position)
			}
			s.delay = s.config.etch_delay
		} else {
			s.delay -= 1
		}
	}

	current_coords := e.chars.current_coord
	visual_symbols := e.chars.visual
	visual_fg := e.chars.visual
	input_symbols := e.chars.input_symbol
	// Only the short cooling tail needs updates. Completed source glyphs retain
	// their final visual, so scanning the full input every frame is wasted work.
	source_lifetime := 3 + len(s.cool_spectrum) * 3 + 8 * s.config.final_gradient_frames + 1
	source_write := 0
	for i in s.active_sources {
		id := s.characters[i]
		start := s.source_starts[i]
		age := s.tick - start
		if age >= source_lifetime {
			visual_symbols[id].symbol = input_symbols[id]
			visual_fg[id].fg = s.final_colors[i]
			continue
		}
		visual_symbols[id].symbol = age < 3 ? "^" : input_symbols[id]
		if age < 3 {
			visual_fg[id].fg = s.cool_spectrum[0]
		} else if age < 3 + len(s.cool_spectrum) * 3 {
			visual_fg[id].fg = s.cool_spectrum[(age - 3) / 3]
		} else {
			cool_age := age - 3 - len(s.cool_spectrum) * 3
			visual_fg[id].fg = engine.gradient_between_step(
				s.cool_spectrum[len(s.cool_spectrum) - 1],
				s.final_colors[i],
				8,
				min(cool_age / s.config.final_gradient_frames, 8),
			)
		}
		s.active_sources[source_write] = i
		source_write += 1
	}
	resize(&s.active_sources, source_write)

	visible := e.chars.is_visible
	if s.pending_head < len(s.pending) {
		color := s.laser_spectrum[s.beam_color_index]
		for id, beam in s.beam_ids {
			current_coords[id] = engine.coord(
				s.laser_position.column + beam,
				s.laser_position.row + beam,
			)
			visual_fg[id].fg = color
			visible[id] = true
		}
		s.beam_color_index += 1
		if s.beam_color_index == len(s.laser_spectrum) do s.beam_color_index = 0
	} else {
		for id in s.beam_ids do visible[id] = false
	}

	// The backing spark arrays are fixed capacity, while this compact index
	// slice contains only live sparks. It keeps both movement and rendering
	// proportional to live particles rather than input length.
	spark_write := 0
	for i in s.active_sparks {
		id := s.spark_ids[i]
		start := s.spark_starts[i]
		age := s.tick - start
		if age < s.spark_steps[i] {
			current_coords[id] = engine.coord_on_quadratic_bezier(
				s.spark_origins[i],
				s.spark_controls[i],
				s.spark_targets[i],
				ease.ease(.Sine_Out, f64(age + 1) / f64(s.spark_steps[i])),
			)
			visual_fg[id].fg = s.spark_spectrum[0]
		} else {
			cool_age := age - s.spark_steps[i]
			color_step := cool_age / s.config.spark_cooling_frames
			if color_step >= len(s.spark_spectrum) {
				visible[id] = false
				s.spark_starts[i] = -1
				continue
			}
			visual_fg[id].fg = s.spark_spectrum[color_step]
		}
		s.active_sparks[spark_write] = i
		spark_write += 1
	}
	resize(&s.active_sparks, spark_write)

	// Keep the permanent prefix in place; replace only the compact spark tail.
	base_render_count := len(s.characters) + len(s.beam_ids)
	resize(&s.render_ids, base_render_count)
	for i in s.active_sparks do append(&s.render_ids, s.spark_ids[i])
	s.tick += 1
	engine.frame(e, s.render_ids[:])
	return true
}
