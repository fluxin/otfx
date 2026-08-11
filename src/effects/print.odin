package effects

import engine "../engine"

import "core:fmt"
import ease "core:math/ease"

Print_Config :: struct {
	print_head_return_speed:  f64,
	print_speed:              int,
	print_head_easing:        ease.Ease,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

print_config_default :: proc() -> Print_Config {
	cfg := Print_Config {
		print_head_return_speed  = 1.5,
		print_speed              = 2,
		print_head_easing        = .Quadratic_In_Out,
		final_gradient_direction = .Diagonal,
	}
	append(
		&cfg.final_gradient_stops,
		..[]engine.Color {
			engine.Color{0x02, 0xb8, 0xbd},
			engine.Color{0xc1, 0xf0, 0xe3},
			engine.Color{0x00, 0xff, 0xa0},
		},
	)
	append(&cfg.final_gradient_steps, 12)
	return cfg
}

print_parse :: proc(cfg: ^Print_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--print-head-return-speed":
			if !parse_float_flag(&cfg.print_head_return_speed, args, &i, value, has_value) || cfg.print_head_return_speed <= 0 do return false
		case "--print-speed":
			if !parse_int_flag(&cfg.print_speed, args, &i, value, has_value) || cfg.print_speed <= 0 do return false
		case "--print-head-easing":
			if !parse_ease_flag(&cfg.print_head_easing, args, &i, value, has_value) do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown print option: ", name)
			return false
		}
	}
	return true
}

Print_Row :: struct {
	span:  engine.Span,
	typed: int,
}

Print_State :: struct {
	config:             Print_Config,
	row_chars:          [dynamic]engine.Char_Id,
	rows:               [dynamic]Print_Row,
	final_colors:       [dynamic]engine.Color,
	char_start_ticks:   [dynamic]int,
	active_chars:       [dynamic]engine.Char_Id,
	current_row:        int,
	typing_head:        engine.Char_Id,
	typing:             bool,
	last_column:        int,
	head_origin:        engine.Coord,
	head_target:        engine.Coord,
	head_start_tick:    int,
	head_max_steps:     int,
	head_return_active: bool,
	tick:               int,
}

print_row_characters :: proc(s: ^Print_State, row_index: int) -> []engine.Char_Id {
	return engine.span_slice(s.row_chars[:], s.rows[row_index].span)
}

print_row_all_fill :: proc(chars: ^engine.Character_Storage, ids: []engine.Char_Id) -> bool {
	for id in ids {
		if !chars.is_fill[id] do return false
	}
	return true
}

print_build :: proc(s: ^Print_State, e: ^engine.Engine) {
	s.typing_head = engine.add_character(e, "█", engine.coord(1, 1))

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
	characters := engine.get_characters(query, engine.filter_all_fills(), .Top_Bottom_Left_Right)
	defer delete(characters[:])
	s.final_colors = make([dynamic]engine.Color, len(e.chars))
	s.char_start_ticks = make([dynamic]int, len(e.chars))
	for i in 0 ..< len(s.char_start_ticks) do s.char_start_ticks[i] = -1
	white := engine.Color{0xff, 0xff, 0xff}
	for id in characters {
		coord := e.chars.input_coord[id]
		if coord.row >= e.canvas.text_bottom &&
		   coord.row <= e.canvas.text_top &&
		   coord.column >= e.canvas.text_left &&
		   coord.column <= e.canvas.text_right {
			s.final_colors[id] = engine.gradient_sample(sampler, spectrum[:], coord)
		} else {
			s.final_colors[id] = white
		}
	}

	groups := engine.get_characters_grouped(query, engine.filter_all_fills(), .Row_T2B)
	defer engine.groups_delete(&groups)
	for group_index in 0 ..< engine.group_count(groups) {
		group := engine.group_slice(groups, group_index)
		all_fill := print_row_all_fill(&e.chars, group)
		right_extent := 0
		if !all_fill {
			for id in group {
				if !e.chars.is_fill[id] do right_extent = max(right_extent, e.chars.input_coord[id].column)
			}
		}
		start := len(s.row_chars)
		for id in group {
			if all_fill && len(s.row_chars) > start do break
			if !all_fill && e.chars.input_coord[id].column > right_extent do continue
			e.chars.current_coord[id] = engine.coord(e.chars.input_coord[id].column, 1)
			append(&s.row_chars, id)
		}
		append(&s.rows, Print_Row{{start, len(s.row_chars) - start}, 0})
	}
	s.typing = len(s.rows) > 0
}

print_next :: proc(s: ^Print_State, e: ^engine.Engine) -> bool {
	white := engine.Color{0xff, 0xff, 0xff}
	if len(s.active_chars) == 0 && !s.typing && !s.head_return_active do return false
	if s.head_return_active {
		// carriage return is still active
	} else if s.typing {
		row := &s.rows[s.current_row]
		characters := print_row_characters(s, s.current_row)
		if row.typed < len(characters) {
			count := min(len(characters) - row.typed, s.config.print_speed)
			for _ in 0 ..< count {
				id := characters[row.typed]
				row.typed += 1
				e.chars.is_visible[id] = true
				s.char_start_ticks[id] = s.tick
				append(&s.active_chars, id)
				s.last_column = e.chars.input_coord[id].column
			}
		} else if s.current_row + 1 < len(s.rows) {
			for row_index in 0 ..= s.current_row {
				processed := &s.rows[row_index]
				ids := print_row_characters(s, row_index)[:processed.typed]
				for id in ids do e.chars.current_coord[id].row += 1
			}
			previous := s.current_row
			s.current_row += 1
			current := &s.rows[s.current_row]
			current_ids := print_row_characters(s, s.current_row)
			previous_ids := print_row_characters(s, previous)[:s.rows[previous].typed]
			if !print_row_all_fill(&e.chars, previous_ids) &&
			   !print_row_all_fill(&e.chars, current_ids) {
				left_extent := e.canvas.right
				for id in current_ids {
					if !e.chars.is_fill[id] do left_extent = min(left_extent, e.chars.input_coord[id].column)
				}
				trim := 0
				for trim < len(current_ids) && e.chars.input_coord[current_ids[trim]].column < left_extent do trim += 1
				current.span.start += trim
				current.span.len -= trim
				current_ids = print_row_characters(s, s.current_row)
			}

			s.head_origin = engine.coord(s.last_column, 1)
			e.chars.current_coord[s.typing_head] = s.head_origin
			e.chars.is_visible[s.typing_head] = true
			target_column := e.chars.input_coord[current_ids[0]].column
			s.head_target = engine.coord(target_column, 1)
			s.head_max_steps = max(
				engine.round_half_even(
					engine.line_length(s.head_origin, s.head_target, true) /
					s.config.print_head_return_speed,
				),
				1,
			)
			s.head_start_tick = s.tick
			s.head_return_active = true
		} else {
			s.typing = false
		}
	}
	write := 0
	for id in s.active_chars {
		age := s.tick - s.char_start_ticks[id]
		if age >= 18 do continue
		frame := min(age / 3, 5)
		if frame < 4 {
			symbols := [4]string{"█", "█", "▓", "▒"}
			e.chars.visual_symbol[id] = symbols[frame]
		} else if frame == 4 {
			e.chars.visual_symbol[id] = "░"
		} else {
			e.chars.visual_symbol[id] = e.chars.input_symbol[id]
		}
		e.chars.visual_fg[id] = engine.gradient_between_step(white, s.final_colors[id], 5, frame)
		if age + 1 < 18 {
			s.active_chars[write] = id
			write += 1
		}
	}
	resize(&s.active_chars, write)
	if s.head_return_active {
		age := s.tick - s.head_start_tick
		progress := f64(age + 1) / f64(s.head_max_steps)
		e.chars.current_coord[s.typing_head] = engine.coord_on_line(
			s.head_origin,
			s.head_target,
			ease.ease(s.config.print_head_easing, progress),
		)
		if age + 1 >= s.head_max_steps {
			e.chars.current_coord[s.typing_head] = s.head_target
			e.chars.is_visible[s.typing_head] = false
			s.head_return_active = false
		}
	}
	s.tick += 1
	engine.frame(e)
	return true
}
