package effects

import engine "../engine"
import rand "core:math/rand"

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
	final_colors:      [dynamic]engine.Color_Pair,
	row_scenes:        [dynamic]int,
	col_scenes:        [dynamic]int,
	brighten_scenes:   [dynamic]int,
	group_chars:       [dynamic]engine.Char_Id,
	groups:            [dynamic]Beam_Group,
	pending:           [dynamic]int, // group handles
	pending_head:      int,
	active:            [dynamic]int,
	final_wipe_groups: engine.Char_Groups,
	final_wipe_idx:    int,
	delay:             int,
	phase:             Beams_Phase,
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
	if rand.int_max(2) == 0 do engine.reverse_slice(g)
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
		engine.filter_all_fills(),
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

	chars := engine.get_characters(
		engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas},
		engine.filter_all_fills(),
		.Top_Bottom_Left_Right,
	)
	defer delete(chars[:])
	max_slot := 0
	for id in chars do max_slot = max(max_slot, int(id))
	s.final_colors = make([dynamic]engine.Color_Pair, max_slot + 1)
	s.row_scenes = make([dynamic]int, max_slot + 1)
	s.col_scenes = make([dynamic]int, max_slot + 1)
	s.brighten_scenes = make([dynamic]int, max_slot + 1)
	for i in 0 ..= max_slot do s.row_scenes[i], s.col_scenes[i], s.brighten_scenes[i] = -1, -1, -1

	black := engine.Color{0x00, 0x00, 0x00}
	for id in chars {
		if e.chars.is_fill[id] {
			s.final_colors[id] = engine.Color_Pair {
				fg = black,
				bg = nil,
			}
			continue
		}
		c := e.chars.input_coord[id]
		s.final_colors[id] = engine.Color_Pair {
			fg = engine.gradient_sample(final_sampler, final_spectrum[:], c),
			bg = nil,
		}
	}

	// scenes on the row pass only (rows and columns share characters)
	row_groups := engine.get_characters_grouped(
		engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas},
		engine.filter_all_fills(),
		.Row_B2T,
	)
	for gi in 0 ..< engine.group_count(row_groups) {
		g := engine.group_slice(row_groups, gi)
		append(&s.groups, beams_make_group(&s.group_chars, g, .Row, s.config.beam_row_speed_range))
	}
	engine.groups_delete(&row_groups)
	col_groups := engine.get_characters_grouped(
		engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas},
		engine.filter_all_fills(),
		.Column_L2R,
	)
	for gi in 0 ..< engine.group_count(col_groups) {
		g := engine.group_slice(col_groups, gi)
		append(
			&s.groups,
			beams_make_group(&s.group_chars, g, .Column, s.config.beam_column_speed_range),
		)
	}
	engine.groups_delete(&col_groups)

	for gi in 0 ..< len(s.groups) {
		group := &s.groups[gi]
		if group.direction != .Row do continue
		for id in engine.span_slice(s.group_chars[:], group.span) {
			sym := e.chars.input_symbol[id]
			final := s.final_colors[id]
			faded := engine.adjust_color_brightness(final.fg.?, 0.3)
			fade := engine.gradient_with_steps([]engine.Color{final.fg.?, faded}, 10, false)
			defer delete(fade[:])
			brighten := engine.gradient_with_steps([]engine.Color{faded, final.fg.?}, 10, false)
			defer delete(brighten[:])

			row_scn := engine.new_scene(e, false, .None, {})
			engine.scene_add_gradient(
				&e.scenes[row_scn],
				s.config.beam_row_symbols[:],
				s.config.beam_gradient_frames,
				beam_spectrum[:],
				nil,
			)
			engine.scene_add_gradient(&e.scenes[row_scn], []string{sym}, 2, fade[:], nil)
			s.row_scenes[id] = row_scn

			col_scn := engine.new_scene(e, false, .None, {})
			engine.scene_add_gradient(
				&e.scenes[col_scn],
				s.config.beam_column_symbols[:],
				s.config.beam_gradient_frames,
				beam_spectrum[:],
				nil,
			)
			engine.scene_add_gradient(&e.scenes[col_scn], []string{sym}, 2, fade[:], nil)
			s.col_scenes[id] = col_scn

			brighten_scn := engine.new_scene(e, false, .None, {})
			engine.scene_add_gradient(
				&e.scenes[brighten_scn],
				[]string{sym},
				s.config.final_gradient_frames,
				brighten[:],
				nil,
			)
			s.brighten_scenes[id] = brighten_scn
		}
	}

	for gi in 0 ..< len(s.groups) do append(&s.pending, gi)
	rand.shuffle(s.pending[:])
}

// Release one character from a beam group. Crossings reset and switch scenes;
// only a character not already active needs insertion into the active set.
beams_release_char :: proc(
	group_chars: []engine.Char_Id,
	row_scenes, col_scenes: []int,
	e: ^engine.Engine,
	group: ^Beam_Group,
) -> (
	engine.Char_Id,
	bool,
) {
	group.counter -= 1
	next := group_chars[group.span.start + group.head]
	group.head += 1
	if e.chars.active_scene[next] >= 0 {
		engine.scene_reset(&e.scenes[e.chars.active_scene[next]])
	} else {
		e.chars.is_visible[next] = true
	}
	scene_handle := group.direction == .Row ? row_scenes[next] : col_scenes[next]
	engine.activate_scene(e, next, scene_handle)
	// A crossing beam resets the old scene and immediately switches direction,
	// but the character is already in the active set. A fresh character needs
	// insertion so it advances on subsequent frames.
	return next, e.in_active[next] == 0
}

beams_next :: proc(s: ^Beams_State, e: ^engine.Engine) -> bool {
	if s.phase == .Complete && len(e.active) == 0 {
		return false
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
					ch, insert := beams_release_char(
						s.group_chars[:],
						s.row_scenes[:],
						s.col_scenes[:],
						e,
						group,
					)
					if insert do engine.active_insert(e, ch)
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
		if s.pending_head == len(s.pending) && len(s.active) == 0 && len(e.active) == 0 {
			s.phase = .Final_Wipe
		}
	case .Final_Wipe:
		if s.final_wipe_idx < engine.group_count(s.final_wipe_groups) {
			for _ in 0 ..< s.config.final_wipe_speed {
				if s.final_wipe_idx >= engine.group_count(s.final_wipe_groups) do break
				g := engine.group_slice(s.final_wipe_groups, s.final_wipe_idx)
				s.final_wipe_idx += 1
				for id in g {
					engine.activate_scene(e, id, s.brighten_scenes[id])
					e.chars.is_visible[id] = true
					engine.active_insert(e, id)
				}
			}
		} else {
			s.phase = .Complete
		}
	case .Complete:
	}
	engine.update(e)
	engine.frame(e)
	return true
}
