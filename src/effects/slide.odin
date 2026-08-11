package effects

import engine "../engine"

import "core:fmt"
import ease "core:math/ease"
import "core:slice"

// slide — characters slide in from outside the canvas, group by group.

Slide_Grouping :: enum {
	Row,
	Column,
	Diagonal,
}

Slide_Config :: struct {
	movement_speed:           f64,
	grouping:                 Slide_Grouping,
	gap:                      int,
	reverse_direction:        bool,
	merge:                    bool,
	movement_easing:          ease.Ease,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_frames:    int,
	final_gradient_direction: engine.Gradient_Direction,
}

slide_config_default :: proc() -> Slide_Config {
	cfg := Slide_Config {
		movement_speed           = 0.8,
		grouping                 = .Row,
		gap                      = 2,
		movement_easing          = .Quadratic_In_Out,
		final_gradient_frames    = 6,
		final_gradient_direction = .Vertical,
	}
	append(
		&cfg.final_gradient_stops,
		..[]engine.Color {
			engine.Color{0x83, 0x3a, 0xb4},
			engine.Color{0xfd, 0x1d, 0x1d},
			engine.Color{0xfc, 0xb0, 0x45},
		},
	)
	append(&cfg.final_gradient_steps, 12)
	return cfg
}

slide_parse :: proc(cfg: ^Slide_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--movement-speed":
			if !parse_float_flag(&cfg.movement_speed, args, &i, value, has_value) do return false
		case "--grouping":
			v, ok := opt_value(args, &i, value, has_value)
			if !ok do return false
			switch v {
			case "row":
				cfg.grouping = .Row
			case "column":
				cfg.grouping = .Column
			case "diagonal":
				cfg.grouping = .Diagonal
			case:
				return false
			}
		case "--gap":
			if !parse_int_flag(&cfg.gap, args, &i, value, has_value) do return false
		case "--reverse-direction":
			cfg.reverse_direction = true
		case "--merge":
			cfg.merge = true
		case "--movement-easing":
			if !parse_ease_flag(&cfg.movement_easing, args, &i, value, has_value) do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-frames":
			if !parse_int_flag(&cfg.final_gradient_frames, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown slide option: ", name)
			return false
		}
	}
	return true
}

Slide_State :: struct {
	config:       Slide_Config,
	characters:   [dynamic]engine.Char_Id,
	index_by_id:  [dynamic]int,
	final_colors: [dynamic]engine.Color,
	groups:       engine.Char_Groups,
	heads:        [dynamic]int,
	origins:      [dynamic]engine.Coord,
	steps:        [dynamic]int,
	max_steps:    [dynamic]int,
	active_slots: [dynamic]int,
	next_group:   int,
	current_gap:  int,
}

slide_build :: proc(s: ^Slide_State, e: ^engine.Engine) {
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
	n := len(s.characters)
	s.index_by_id = make([dynamic]int, len(e.chars))
	s.final_colors = make([dynamic]engine.Color, n)
	s.origins = make([dynamic]engine.Coord, n)
	s.steps = make([dynamic]int, n)
	s.max_steps = make([dynamic]int, n)
	for id, i in s.characters {
		c := e.chars.input_coord[id]
		s.index_by_id[id] = i
		s.final_colors[i] = engine.gradient_sample(sampler, spectrum[:], c)
		engine.character_set_visual(
			&e.chars,
			id,
			{symbol = e.chars.input_symbol[id], fg = s.config.final_gradient_stops[0]},
		)
	}

	grouping: engine.Character_Group = .Row_T2B
	switch s.config.grouping {
	case .Row:
		grouping = .Row_T2B
	case .Column:
		grouping = .Column_L2R
	case .Diagonal:
		grouping = .Diagonal_TL2BR
	}
	s.groups = engine.get_characters_grouped(
		engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas},
		engine.CHAR_FILTER_INPUT,
		grouping,
	)

	// Starting positions and fixed direct-motion rows. Reversals happen on the
	// flat group slice, matching the source ordering without path objects.
	for gi in 0 ..< len(s.groups.spans) {
		g := engine.group_members(s.groups, gi)
		switch s.config.grouping {
		case .Row:
			start_col := e.canvas.left - 1
			if s.config.merge && gi % 2 == 0 {
				start_col = e.canvas.right + 1
			} else {
				slice.reverse(g)
			}
			if s.config.reverse_direction && !s.config.merge {
				slice.reverse(g)
				start_col = e.canvas.right + 1
			}
			for id in g do e.chars.current_coord[id] = engine.coord(start_col, e.chars.input_coord[id].row)
		case .Column:
			start_row := e.canvas.top + 1
			if s.config.merge && gi % 2 == 0 {
				start_row = e.canvas.bottom - 1
			} else {
				slice.reverse(g)
			}
			if s.config.reverse_direction && !s.config.merge {
				slice.reverse(g)
				start_row = e.canvas.bottom - 1
			}
			for id in g do e.chars.current_coord[id] = engine.coord(e.chars.input_coord[id].column, start_row)
		case .Diagonal:
			last := e.chars.input_coord[g[len(g) - 1]]
			d := last.row - (e.canvas.bottom - 1)
			start := engine.coord(last.column - d, last.row - d)
			if s.config.merge && gi % 2 == 0 {
				slice.reverse(g)
				first := e.chars.input_coord[g[0]]
				d := (e.canvas.top + 1) - first.row
				start = engine.coord(first.column + d, first.row + d)
			}
			if s.config.reverse_direction && !s.config.merge {
				slice.reverse(g)
				first := e.chars.input_coord[g[0]]
				d := (e.canvas.top + 1) - first.row
				start = engine.coord(first.column + d, first.row + d)
			}
			for id in g do e.chars.current_coord[id] = start
		}
		for id in g {
			i := s.index_by_id[id]
			s.origins[i] = e.chars.current_coord[id]
			s.max_steps[i] = max(
				engine.round_half_even(
					engine.line_length(s.origins[i], e.chars.input_coord[id], true) /
					s.config.movement_speed,
				),
				1,
			)
		}
	}
	s.heads = make([dynamic]int, len(s.groups.spans))
}

slide_next :: proc(s: ^Slide_State, e: ^engine.Engine) -> bool {
	if s.next_group >= len(s.groups.spans) && len(s.active_slots) == 0 {
		return false
	}
	if s.current_gap == s.config.gap && s.next_group < len(s.groups.spans) {
		s.next_group += 1
		s.current_gap = 0
	} else if s.next_group < len(s.groups.spans) {
		s.current_gap += 1
	}
	// release the front character of every active group
	for gi in 0 ..< s.next_group {
		g := engine.group_members(s.groups, gi)
		if s.heads[gi] < len(g) {
			next := g[s.heads[gi]]
			s.heads[gi] += 1
			e.chars.is_visible[next] = true
			append(&s.active_slots, s.index_by_id[next])
		}
	}
	// drop exhausted groups from the front
	for s.next_group < len(s.groups.spans) {
		g := engine.group_members(s.groups, s.next_group)
		if s.heads[s.next_group] >= len(g) {
			s.next_group += 1
		} else {
			break
		}
	}
	write := 0
	base_color := s.config.final_gradient_stops[0]
	gradient_ticks := 10 * s.config.final_gradient_frames
	for i in s.active_slots {
		id := s.characters[i]
		step := s.steps[i]
		if step < s.max_steps[i] {
			progress := f64(step + 1) / f64(s.max_steps[i])
			e.chars.current_coord[id] = engine.coord_on_line(
				s.origins[i],
				e.chars.input_coord[id],
				ease.ease(s.config.movement_easing, progress),
			)
		}
		gradient_step := min(step / max(s.config.final_gradient_frames, 1), 10)
		e.chars.visual[id].fg = engine.gradient_between_step(
			base_color,
			s.final_colors[i],
			10,
			gradient_step,
		)
		s.steps[i] += 1
		if s.steps[i] < max(s.max_steps[i], gradient_ticks) {
			s.active_slots[write] = i
			write += 1
		} else {
			e.chars.current_coord[id] = e.chars.input_coord[id]
			e.chars.visual[id].fg = s.final_colors[i]
		}
	}
	resize(&s.active_slots, write)
	engine.frame(e, s.characters[:])
	return true
}
