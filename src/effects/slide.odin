package effects

import engine "../engine"

import "core:fmt"

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
	movement_easing:          engine.Easing,
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
		movement_easing          = engine.ease_of(.Quadratic_In_Out),
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
	config:        Slide_Config,
	final_colors:  [dynamic]engine.Color_Pair, // indexed by arena slot
	groups:        engine.Char_Groups, // all groups, one flat pool
	heads:         [dynamic]int, // per-group consumption cursor
	path_handles:  [dynamic]int, // per arena slot
	scene_handles: [dynamic]int, // per arena slot
	next_group:    int, // first not-yet-activated group
	current_gap:   int,
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

	chars := engine.get_characters(
		engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas},
		engine.filter_input(),
		.Top_Bottom_Left_Right,
	)
	defer delete(chars[:])
	max_slot := 0
	for id in chars do max_slot = max(max_slot, int(id))
	s.final_colors = make([dynamic]engine.Color_Pair, max_slot + 1)
	s.path_handles = make([dynamic]int, max_slot + 1)
	s.scene_handles = make([dynamic]int, max_slot + 1)
	for i in 0 ..= max_slot do s.path_handles[i], s.scene_handles[i] = -1, -1

	for id in chars {
		c := e.chars.input_coord[id]
		s.final_colors[id] = {
			fg = engine.gradient_sample(sampler, spectrum[:], c),
			bg = nil,
		}
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
		engine.filter_input(),
		grouping,
	)

	// input path: one waypoint at the home coordinate
	for gi in 0 ..< engine.group_count(s.groups) {
		for id in engine.group_slice(s.groups, gi) {
			p := engine.new_path(
				e,
				s.config.movement_speed,
				s.config.movement_easing,
				nil,
				0,
				false,
			)
			engine.path_add_waypoint(&e.paths[p], e.chars.input_coord[id])
			s.path_handles[id] = p
		}
	}

	// starting positions, per group (reversals happen on the flat slice)
	for gi in 0 ..< engine.group_count(s.groups) {
		g := engine.group_slice(s.groups, gi)
		switch s.config.grouping {
		case .Row:
			start_col := e.canvas.left - 1
			if s.config.merge && gi % 2 == 0 {
				start_col = e.canvas.right + 1
			} else {
				engine.reverse_slice(g)
			}
			if s.config.reverse_direction && !s.config.merge {
				engine.reverse_slice(g)
				start_col = e.canvas.right + 1
			}
			for id in g do e.chars.current_coord[id] = engine.coord(start_col, e.chars.input_coord[id].row)
		case .Column:
			start_row := e.canvas.top + 1
			if s.config.merge && gi % 2 == 0 {
				start_row = e.canvas.bottom - 1
			} else {
				engine.reverse_slice(g)
			}
			if s.config.reverse_direction && !s.config.merge {
				engine.reverse_slice(g)
				start_row = e.canvas.bottom - 1
			}
			for id in g do e.chars.current_coord[id] = engine.coord(e.chars.input_coord[id].column, start_row)
		case .Diagonal:
			last := e.chars.input_coord[g[len(g) - 1]]
			d := last.row - (e.canvas.bottom - 1)
			start := engine.coord(last.column - d, last.row - d)
			if s.config.merge && gi % 2 == 0 {
				engine.reverse_slice(g)
				first := e.chars.input_coord[g[0]]
				d := (e.canvas.top + 1) - first.row
				start = engine.coord(first.column + d, first.row + d)
			}
			if s.config.reverse_direction && !s.config.merge {
				engine.reverse_slice(g)
				first := e.chars.input_coord[g[0]]
				d := (e.canvas.top + 1) - first.row
				start = engine.coord(first.column + d, first.row + d)
			}
			for id in g do e.chars.current_coord[id] = start
		}
		// gradient scene per character
		for id in g {
			final := s.final_colors[id]
			sc := engine.new_scene(e, false, .None, {})
			gg := engine.gradient_with_steps(
				[]engine.Color{s.config.final_gradient_stops[0], final.fg.?},
				10,
				false,
			)
			defer delete(gg[:])
			engine.scene_add_gradient(
				&e.scenes[sc],
				[]string{e.chars.input_symbol[id]},
				s.config.final_gradient_frames,
				gg[:],
				nil,
			)
			engine.activate_scene(e, id, sc)
			s.scene_handles[id] = sc
		}
	}
	s.heads = make([dynamic]int, engine.group_count(s.groups))
}

slide_next :: proc(s: ^Slide_State, e: ^engine.Engine) -> bool {
	if s.next_group >= engine.group_count(s.groups) && len(e.active) == 0 {
		return false
	}
	if s.current_gap == s.config.gap && s.next_group < engine.group_count(s.groups) {
		s.next_group += 1
		s.current_gap = 0
	} else if s.next_group < engine.group_count(s.groups) {
		s.current_gap += 1
	}
	// release the front character of every active group
	for gi in 0 ..< s.next_group {
		g := engine.group_slice(s.groups, gi)
		if s.heads[gi] < len(g) {
			next := g[s.heads[gi]]
			s.heads[gi] += 1
			e.chars.is_visible[next] = true
			engine.activate_path(e, next, s.path_handles[next])
			engine.active_insert(e, next)
		}
	}
	// drop exhausted groups from the front
	for s.next_group < engine.group_count(s.groups) {
		g := engine.group_slice(s.groups, s.next_group)
		if s.heads[s.next_group] >= len(g) {
			s.next_group += 1
		} else {
			break
		}
	}
	engine.update(e)
	engine.frame(e)
	return true
}
