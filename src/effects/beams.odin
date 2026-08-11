package effects

import "../engine"
import "core:math/rand"
import "core:slice"

import "core:fmt"

// beams — light beams sweep rows and columns illuminating the canvas, then a
// final wipe brightens everything into place.

Beams_Config :: struct {
	beam_row_symbols:         [dynamic]string,
	beam_column_symbols:      [dynamic]string,
	beam_delay:               int,
	beam_row_speed_range:     Int_Range_Value,
	beam_column_speed_range:  Int_Range_Value,
	beam_gradient_stops:      [dynamic]engine.Color,
	beam_gradient_steps:      [dynamic]int,
	beam_gradient_frames:     int,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_frames:    int,
	final_gradient_direction: engine.Gradient_Direction,
	final_wipe_speed:         int,
}

beams_config_default :: proc() -> Beams_Config {
	cfg := Beams_Config {
		beam_delay               = 6,
		beam_row_speed_range     = {15, 60},
		beam_column_speed_range  = {9, 15},
		beam_gradient_frames     = 2,
		final_gradient_frames    = 4,
		final_gradient_direction = .Vertical,
		final_wipe_speed         = 3,
	}
	append(&cfg.beam_row_symbols, ..[]string{"▂", "▁", "_"})
	append(&cfg.beam_column_symbols, ..[]string{"▌", "▍", "▎", "▏"})
	append(
		&cfg.beam_gradient_stops,
		..[]engine.Color {
			engine.Color{0xff, 0xff, 0xff},
			engine.Color{0x00, 0xD1, 0xFF},
			engine.Color{0x8A, 0x00, 0x8A},
		},
	)
	append(&cfg.beam_gradient_steps, ..[]int{2, 6})
	append(
		&cfg.final_gradient_stops,
		..[]engine.Color {
			engine.Color{0x8A, 0x00, 0x8A},
			engine.Color{0x00, 0xD1, 0xFF},
			engine.Color{0xff, 0xff, 0xff},
		},
	)
	append(&cfg.final_gradient_steps, 12)
	return cfg
}

beams_parse :: proc(cfg: ^Beams_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--beam-row-symbols":
			if !parse_symbols_flag(&cfg.beam_row_symbols, args, &i, value, has_value) do return false
		case "--beam-column-symbols":
			if !parse_symbols_flag(&cfg.beam_column_symbols, args, &i, value, has_value) do return false
		case "--beam-delay":
			if !parse_int_flag(&cfg.beam_delay, args, &i, value, has_value) do return false
		case "--beam-row-speed-range":
			if !parse_int_range_flag(&cfg.beam_row_speed_range, args, &i, value, has_value) do return false
		case "--beam-column-speed-range":
			if !parse_int_range_flag(&cfg.beam_column_speed_range, args, &i, value, has_value) do return false
		case "--beam-gradient-stops":
			if !parse_colors_flag(&cfg.beam_gradient_stops, args, &i, value, has_value) do return false
		case "--beam-gradient-steps":
			if !parse_ints_flag(&cfg.beam_gradient_steps, args, &i, value, has_value) do return false
		case "--beam-gradient-frames":
			if !parse_int_flag(&cfg.beam_gradient_frames, args, &i, value, has_value) do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-frames":
			if !parse_int_flag(&cfg.final_gradient_frames, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case "--final-wipe-speed":
			if !parse_int_flag(&cfg.final_wipe_speed, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown beams option: ", name)
			return false
		}
	}
	return true
}

Beam_Direction :: enum {
	Row,
	Column,
}

// A beam group is a span into the flat character pool plus its own cursor.
Beam_Group :: struct {
	span:      engine.Span,
	head:      int,
	direction: Beam_Direction,
	speed:     f64,
	counter:   f64,
}

Beams_Phase :: enum {
	Beams,
	Final_Wipe,
	Complete,
}

Beams_State :: struct {
	config:            Beams_Config,
	characters:        [dynamic]engine.Char_Id,
	final_colors:      [dynamic]engine.Color,
	faded_colors:      [dynamic]engine.Color,
	beam_start_ticks:  [dynamic]int,
	beam_modes:        [dynamic]Beam_Direction,
	wipe_start_ticks:  [dynamic]int,
	beam_palette:      [dynamic]engine.Color,
	row_symbols:       [dynamic]string,
	column_symbols:    [dynamic]string,
	group_chars:       [dynamic]engine.Char_Id,
	groups:            [dynamic]Beam_Group,
	pending:           [dynamic]int, // group handles
	pending_head:      int,
	active:            [dynamic]int,
	final_wipe_groups: engine.Char_Groups,
	final_wipe_idx:    int,
	delay:             int,
	tick:              int,
	phase:             Beams_Phase,
}

// Expand symbols with the same contiguous distribution used by
// scene_add_gradient. It is build-only; playback indexes this flat row.
beams_expand_symbols :: proc(symbols: []string, count: int) -> [dynamic]string {
	out := make([dynamic]string, count)
	repeat_factor := count / len(symbols)
	overflow_count := count % len(symbols)
	symbol_index, current_repeat := 0, 0
	overflow_used := false
	for i in 0 ..< count {
		if current_repeat >= repeat_factor {
			if overflow_count > 0 {
				if overflow_used {
					symbol_index += 1
					current_repeat = 0
					overflow_used = false
				} else {
					overflow_used = true
					overflow_count -= 1
				}
			} else {
				symbol_index += 1
				current_repeat = 0
			}
		}
		current_repeat += 1
		out[i] = symbols[symbol_index]
	}
	return out
}

beams_make_group :: proc(
	group_chars: ^[dynamic]engine.Char_Id,
	g: []engine.Char_Id,
	direction: Beam_Direction,
	rng: Int_Range_Value,
) -> Beam_Group {
	speed := f64(rand.int_range(rng.lo, rng.hi + 1)) * 0.1
	// get_characters_grouped already orders row groups by column and column
	// groups by row. Consume that producer contract instead of sorting again.
	if rand.int_max(2) == 0 do slice.reverse(g)
	span := engine.Span {
		start = len(group_chars),
		len   = len(g),
	}
	append(group_chars, ..g)
	return {span = span, direction = direction, speed = speed}
}

beams_build :: proc(s: ^Beams_State, e: ^engine.Engine) {
	s.final_wipe_groups = engine.get_characters_grouped(
		engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas},
		engine.CHAR_FILTER_ALL_FILLS,
		.Diagonal_TL2BR,
	)

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
	beam_spectrum := engine.gradient_make(
		s.config.beam_gradient_stops[:],
		s.config.beam_gradient_steps[:],
		false,
	)
	defer delete(beam_spectrum[:])

	s.characters = engine.get_characters(
		engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas},
		engine.CHAR_FILTER_ALL_FILLS,
		.Top_Bottom_Left_Right,
	)
	max_slot := 0
	for id in s.characters do max_slot = max(max_slot, int(id))
	s.final_colors = make([dynamic]engine.Color, max_slot + 1)
	s.faded_colors = make([dynamic]engine.Color, max_slot + 1)
	s.beam_start_ticks = make([dynamic]int, max_slot + 1)
	s.beam_modes = make([dynamic]Beam_Direction, max_slot + 1)
	s.wipe_start_ticks = make([dynamic]int, max_slot + 1)
	for i in 0 ..= max_slot do s.beam_start_ticks[i], s.wipe_start_ticks[i] = -1, -1

	black := engine.Color{0x00, 0x00, 0x00}
	for id in s.characters {
		if e.chars.is_fill[id] {
			s.final_colors[id] = black
			s.faded_colors[id] = black
			continue
		}
		c := e.chars.input_coord[id]
		s.final_colors[id] = engine.gradient_sample(final_sampler, final_spectrum[:], c)
		s.faded_colors[id] = engine.adjust_color_brightness(s.final_colors[id], 0.3)
	}

	// scenes on the row pass only (rows and columns share characters)
	row_groups := engine.get_characters_grouped(
		engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas},
		engine.CHAR_FILTER_ALL_FILLS,
		.Row_B2T,
	)
	for gi in 0 ..< len(row_groups.spans) {
		g := engine.group_members(row_groups, gi)
		append(&s.groups, beams_make_group(&s.group_chars, g, .Row, s.config.beam_row_speed_range))
	}
	engine.groups_delete(&row_groups)
	col_groups := engine.get_characters_grouped(
		engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas},
		engine.CHAR_FILTER_ALL_FILLS,
		.Column_L2R,
	)
	for gi in 0 ..< len(col_groups.spans) {
		g := engine.group_members(col_groups, gi)
		append(
			&s.groups,
			beams_make_group(&s.group_chars, g, .Column, s.config.beam_column_speed_range),
		)
	}
	engine.groups_delete(&col_groups)

	s.beam_palette = beam_spectrum
	beam_spectrum = nil
	s.row_symbols = beams_expand_symbols(s.config.beam_row_symbols[:], len(s.beam_palette))
	s.column_symbols = beams_expand_symbols(s.config.beam_column_symbols[:], len(s.beam_palette))

	for gi in 0 ..< len(s.groups) do append(&s.pending, gi)
	rand.shuffle(s.pending[:])
}

beams_release_char :: proc(s: ^Beams_State, e: ^engine.Engine, group: ^Beam_Group) {
	group.counter -= 1
	next := s.group_chars[group.span.start + group.head]
	group.head += 1
	s.beam_start_ticks[next] = s.tick
	s.beam_modes[next] = group.direction
	e.chars.is_visible[next] = true
}

beams_beam_active :: proc(s: Beams_State) -> bool {
	beam_ticks := len(s.beam_palette) * s.config.beam_gradient_frames + 22
	for id in s.characters {
		start := s.beam_start_ticks[id]
		if start >= 0 && s.tick - start < beam_ticks do return true
	}
	return false
}

beams_wipe_active :: proc(s: Beams_State) -> bool {
	wipe_ticks := 11 * s.config.final_gradient_frames
	for id in s.characters {
		start := s.wipe_start_ticks[id]
		if start >= 0 && s.tick - start < wipe_ticks do return true
	}
	return false
}

beams_update_visuals :: proc(s: Beams_State, e: ^engine.Engine) {
	beam_ticks := len(s.beam_palette) * s.config.beam_gradient_frames + 22
	for id in s.characters {
		beam_start := s.beam_start_ticks[id]
		if beam_start >= 0 {
			age := s.tick - beam_start
			if age < beam_ticks {
				palette_index := age / s.config.beam_gradient_frames
				if palette_index < len(s.beam_palette) {
					symbols := s.beam_modes[id] == .Row ? s.row_symbols : s.column_symbols
					e.chars.visual[id].symbol = symbols[palette_index]
					e.chars.visual[id].fg = s.beam_palette[palette_index]
				} else {
					e.chars.visual[id].symbol = e.chars.input_symbol[id]
					e.chars.visual[id].fg = engine.gradient_between_step(
						s.final_colors[id],
						s.faded_colors[id],
						10,
						min((age - len(s.beam_palette) * s.config.beam_gradient_frames) / 2, 10),
					)
				}
				continue
			}
		}
		wipe_start := s.wipe_start_ticks[id]
		if wipe_start >= 0 {
			age := s.tick - wipe_start
			if age < 11 * s.config.final_gradient_frames {
				e.chars.visual[id].symbol = e.chars.input_symbol[id]
				e.chars.visual[id].fg = engine.gradient_between_step(
					s.faded_colors[id],
					s.final_colors[id],
					10,
					min(age / s.config.final_gradient_frames, 10),
				)
			}
		}
	}
}

beams_next :: proc(s: ^Beams_State, e: ^engine.Engine) -> ([]engine.Char_Id, bool) {
	if s.phase == .Complete && !beams_wipe_active(s^) {
		return nil, false
	}
	switch s.phase {
	case .Beams:
		if s.delay == 0 {
			if s.pending_head < len(s.pending) {
				for _ in 0 ..< rand.int_range(1, 6) {
					if s.pending_head == len(s.pending) do break
					append(&s.active, s.pending[s.pending_head])
					s.pending_head += 1
				}
			}
			s.delay = s.config.beam_delay
		} else {
			s.delay -= 1
		}
		// release characters per group speed
		for ai in 0 ..< len(s.active) {
			group := &s.groups[s.active[ai]]
			group.counter += group.speed
			count := int(group.counter)
			if count > 1 {
				for _ in 0 ..< count {
					if group.head >= group.span.len do break
					beams_release_char(s, e, group)
				}
			}
		}
		// drop exhausted groups
		write := 0
		for ai in 0 ..< len(s.active) {
			group := &s.groups[s.active[ai]]
			if group.head < group.span.len {
				s.active[write] = s.active[ai]
				write += 1
			}
		}
		resize(&s.active, write)
		if s.pending_head == len(s.pending) && len(s.active) == 0 && !beams_beam_active(s^) {
			s.phase = .Final_Wipe
		}
	case .Final_Wipe:
		if s.final_wipe_idx < len(s.final_wipe_groups.spans) {
			for _ in 0 ..< s.config.final_wipe_speed {
				if s.final_wipe_idx >= len(s.final_wipe_groups.spans) do break
				g := engine.group_members(s.final_wipe_groups, s.final_wipe_idx)
				s.final_wipe_idx += 1
				for id in g {
					s.wipe_start_ticks[id] = s.tick
					e.chars.is_visible[id] = true
				}
			}
		} else {
			s.phase = .Complete
		}
	case .Complete:
	}
	beams_update_visuals(s^, e)
	s.tick += 1
	return s.characters[:], true
}
