package effects

import "../engine"
import "core:math/ease"
import "core:math/rand"

import "core:fmt"
import "core:slice"

// rain — raindrops fall from the top of the canvas; on landing they fade
// into the final gradient.

Rain_Config :: struct {
	rain_colors:              [dynamic]engine.Color,
	movement_speed:           Float_Range_Value,
	rain_symbols:             [dynamic]string,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
	movement_easing:          ease.Ease,
}

rain_config_default :: proc() -> Rain_Config {
	cfg := Rain_Config {
		movement_speed           = {0.33, 0.57},
		final_gradient_direction = .Diagonal,
		movement_easing          = .Quartic_In,
	}
	append(
		&cfg.rain_colors,
		..[]engine.Color {
			engine.Color{0x00, 0x31, 0x5C},
			engine.Color{0x00, 0x4C, 0x8F},
			engine.Color{0x00, 0x75, 0xDB},
			engine.Color{0x3F, 0x91, 0xD9},
			engine.Color{0x78, 0xB9, 0xF2},
			engine.Color{0x9A, 0xC8, 0xF5},
			engine.Color{0xB8, 0xD8, 0xF8},
			engine.Color{0xE3, 0xEF, 0xFC},
		},
	)
	append(&cfg.rain_symbols, ..[]string{"o", ".", ",", "*", "|"})
	append(
		&cfg.final_gradient_stops,
		..[]engine.Color {
			engine.Color{0x48, 0x8b, 0xff},
			engine.Color{0xb2, 0xe7, 0xde},
			engine.Color{0x57, 0xea, 0xf7},
		},
	)
	append(&cfg.final_gradient_steps, 12)
	return cfg
}

rain_parse :: proc(cfg: ^Rain_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--rain-colors":
			if !parse_colors_flag(&cfg.rain_colors, args, &i, value, has_value) do return false
		case "--movement-speed":
			if !parse_float_range_flag(&cfg.movement_speed, args, &i, value, has_value) do return false
		case "--rain-symbols":
			if !parse_symbols_flag(&cfg.rain_symbols, args, &i, value, has_value) do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case "--movement-easing":
			if !parse_ease_flag(&cfg.movement_easing, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown rain option: ", name)
			return false
		}
	}
	return true
}

Rain_State :: struct {
	config:       Rain_Config,
	characters:   [dynamic]engine.Char_Id,
	index_by_id:  [dynamic]int,
	pending:      [dynamic]engine.Char_Id,
	by_row:       [dynamic]engine.Char_Id, // flat pool sorted by input row asc
	revealed:     [dynamic]engine.Char_Id,
	final_colors: [dynamic]engine.Color,
	drop_colors:  [dynamic]engine.Color,
	drop_symbols: [dynamic]string,
	max_steps:    [dynamic]int,
	start_ticks:  [dynamic]int,
	by_row_head:  int,
	tick:         int,
}

rain_build :: proc(s: ^Rain_State, e: ^engine.Engine) {
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

	s.characters = engine.get_characters(
		engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas},
		engine.CHAR_FILTER_INPUT,
		.Top_Bottom_Left_Right,
	)
	input_coords := e.chars.input_coord[:]
	Rain_Row :: struct {
		id:          engine.Char_Id,
		row, column: int,
	}
	n := len(s.characters)
	s.index_by_id = make([dynamic]int, len(e.chars))
	s.final_colors = make([dynamic]engine.Color, n)
	s.drop_colors = make([dynamic]engine.Color, n)
	s.drop_symbols = make([dynamic]string, n)
	s.max_steps = make([dynamic]int, n)
	s.start_ticks = make([dynamic]int, n)
	rows := make([]Rain_Row, n)
	defer delete(rows)

	for id, i in s.characters {
		s.index_by_id[id] = i
		c := input_coords[id]
		rows[i] = {id, c.row, c.column}
		s.final_colors[i] = engine.gradient_sample(sampler, spectrum[:], c)
		s.drop_colors[i] = s.config.rain_colors[rand.int_max(len(s.config.rain_colors))]
		s.drop_symbols[i] = s.config.rain_symbols[rand.int_max(len(s.config.rain_symbols))]
		e.chars.current_coord[id] = engine.coord(c.column, e.canvas.top)
		speed := rand.float64_range(s.config.movement_speed.lo, s.config.movement_speed.hi)
		s.max_steps[i] = max(
			engine.round_half_even(engine.line_length(e.chars.current_coord[id], c, true) / speed),
			1,
		)
		s.start_ticks[i] = -1
	}
	// One flat pool sorted by input row ascending; the front run of equal rows
	// is the min-row group.
	slice.sort_by(rows, proc(a, b: Rain_Row) -> bool {
			if a.row != b.row do return a.row < b.row
			return a.column < b.column
		})
	s.by_row = make([dynamic]engine.Char_Id, len(rows))
	for row, i in rows do s.by_row[i] = row.id
}

rain_next :: proc(s: ^Rain_State, e: ^engine.Engine) -> ([]engine.Char_Id, bool) {
	by_row := s.by_row[:]
	pending := &s.pending
	input_coords := e.chars.input_coord[:]
	visible := e.chars.is_visible[:]
	active := s.by_row_head < len(by_row) || len(pending^) > 0
	for _, i in s.characters {
		start := s.start_ticks[i]
		if start >= 0 && s.tick - start < s.max_steps[i] + 23 {
			active = true
			break
		}
	}
	if !active {
		return nil, false
	}
	if len(pending^) == 0 && s.by_row_head < len(by_row) {
		// Consume the next row span by advancing a cursor; the sorted pool stays
		// fixed instead of shifting every remaining row toward the front.
		row0 := input_coords[by_row[s.by_row_head]].row
		k := s.by_row_head
		for k < len(by_row) && input_coords[by_row[k]].row == row0 {
			k += 1
		}
		append(pending, ..by_row[s.by_row_head:k])
		s.by_row_head = k
	}
	if len(pending^) > 0 {
		for _ in 0 ..< rand.int_range(1, 3) {
			if len(pending^) == 0 do break
			idx := rand.int_max(len(pending^))
			next := pending[idx]
			unordered_remove(pending, idx)
			s.start_ticks[s.index_by_id[next]] = s.tick
			visible[next] = true
			append(&s.revealed, next)
		}
	}
	for id, i in s.characters {
		start := s.start_ticks[i]
		if start < 0 do continue
		age := s.tick - start
		if age < s.max_steps[i] - 1 {
			progress := f64(age + 1) / f64(s.max_steps[i])
			e.chars.current_coord[id] = engine.coord_on_line(
				engine.coord(e.chars.input_coord[id].column, e.canvas.top),
				e.chars.input_coord[id],
				ease.ease(s.config.movement_easing, progress),
			)
			e.chars.visual[id].symbol = s.drop_symbols[i]
			e.chars.visual[id].fg = s.drop_colors[i]
			continue
		}
		e.chars.current_coord[id] = e.chars.input_coord[id]
		e.chars.visual[id].symbol = e.chars.input_symbol[id]
		fade_tick := age - (s.max_steps[i] - 1)
		e.chars.visual[id].fg = engine.gradient_between_step(
			s.drop_colors[i],
			s.final_colors[i],
			7,
			min(fade_tick / 3, 7),
		)
	}
	s.tick += 1
	return s.revealed[:], true
}
