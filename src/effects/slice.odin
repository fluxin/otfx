package effects

import engine "../engine"

import "core:fmt"
import ease "core:math/ease"

Slice_Direction :: enum {
	Vertical,
	Horizontal,
	Diagonal,
}

Slice_Config :: struct {
	slice_direction:          Slice_Direction,
	movement_speed:           f64,
	movement_easing:          ease.Ease,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

slice_config_default :: proc() -> Slice_Config {
	cfg := Slice_Config {
		slice_direction          = .Vertical,
		movement_speed           = 0.25,
		movement_easing          = .Exponential_In_Out,
		final_gradient_direction = .Diagonal,
	}
	append(
		&cfg.final_gradient_stops,
		..[]engine.Color {
			engine.Color{0x8A, 0x00, 0x8A},
			engine.Color{0x00, 0xD1, 0xFF},
			engine.Color{0xFF, 0xFF, 0xFF},
		},
	)
	append(&cfg.final_gradient_steps, 12)
	return cfg
}

slice_parse :: proc(cfg: ^Slice_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--slice-direction":
			v, ok := opt_value(args, &i, value, has_value)
			if !ok do return false
			switch v {
			case "vertical":
				cfg.slice_direction = .Vertical
			case "horizontal":
				cfg.slice_direction = .Horizontal
			case "diagonal":
				cfg.slice_direction = .Diagonal
			case:
				return false
			}
		case "--movement-speed":
			if !parse_float_flag(&cfg.movement_speed, args, &i, value, has_value) || cfg.movement_speed <= 0 do return false
		case "--movement-easing":
			if !parse_ease_flag(&cfg.movement_easing, args, &i, value, has_value) do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown slice option: ", name)
			return false
		}
	}
	return true
}

Slice_State :: struct {
	config:           Slice_Config,
	motion_ids:       [dynamic]engine.Char_Id,
	motion_origins:   [dynamic]engine.Coord,
	motion_steps:     [dynamic]int,
	motion_max_steps: [dynamic]int,
	render_ids:       [dynamic]engine.Char_Id,
}

slice_schedule :: proc(
	s: ^Slice_State,
	e: ^engine.Engine,
	slots: []int,
	id: engine.Char_Id,
	origin: engine.Coord,
	speed: f64,
) {
	slot := slots[id]
	assert(slot >= 0)
	destination := e.chars.input_coord[id]
	e.chars.current_coord[id] = origin
	s.motion_origins[slot] = origin
	s.motion_max_steps[slot] = max(
		engine.round_half_even(engine.line_length(origin, destination, true) / speed),
		1,
	)
}

slice_build :: proc(s: ^Slice_State, e: ^engine.Engine) {
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
	characters := engine.get_characters(query, engine.CHAR_FILTER_INPUT, .Top_Bottom_Left_Right)
	defer delete(characters[:])
	for id in characters {
		color := engine.gradient_sample(sampler, spectrum[:], e.chars.input_coord[id])
		engine.character_set_visual(&e.chars, id, {symbol = e.chars.input_symbol[id], fg = color})
	}

	// Horizontal Slice includes inner fill cells inside the text rectangle;
	// the other directions move input glyphs only. Allocate once, then keep the
	// motion table compact as rows arrive at their destinations.
	if s.config.slice_direction == .Horizontal {
		all_fills := engine.get_characters(
			query,
			engine.CHAR_FILTER_ALL_FILLS,
			.Top_Bottom_Left_Right,
		)
		defer delete(all_fills[:])
		for id in all_fills {
			p := e.chars.input_coord[id]
			if p.column >= e.canvas.text_left &&
			   p.column <= e.canvas.text_right &&
			   p.row >= e.canvas.text_bottom &&
			   p.row <= e.canvas.text_top {
				append(&s.motion_ids, id)
			}
		}
	} else {
		append(&s.motion_ids, ..characters[:])
	}
	n := len(s.motion_ids)
	s.motion_origins = make([dynamic]engine.Coord, n)
	s.motion_steps = make([dynamic]int, n)
	s.motion_max_steps = make([dynamic]int, n)
	reserve(&s.render_ids, n)
	append(&s.render_ids, ..s.motion_ids[:])
	slots := make([dynamic]int, len(e.chars), context.temp_allocator)
	for i in 0 ..< len(slots) do slots[i] = -1
	for id, i in s.motion_ids do slots[id] = i

	speed := s.config.movement_speed
	switch s.config.slice_direction {
	case .Vertical:
		groups := engine.get_characters_grouped(query, engine.CHAR_FILTER_INPUT, .Row_B2T)
		defer engine.groups_delete(&groups)
		count := len(groups.spans)
		for group_index in 0 ..< count {
			for id in engine.group_members(groups, group_index) {
				coord := e.chars.input_coord[id]
				if coord.column <= e.canvas.text_center.column {
					slice_schedule(
						s,
						e,
						slots[:],
						id,
						engine.coord(coord.column, e.canvas.top + 1),
						speed,
					)
				}
			}
			for id in engine.group_members(groups, count - group_index - 1) {
				coord := e.chars.input_coord[id]
				if coord.column > e.canvas.text_center.column {
					slice_schedule(
						s,
						e,
						slots[:],
						id,
						engine.coord(coord.column, e.canvas.bottom - 1),
						speed,
					)
				}
			}
		}
	case .Horizontal:
		speed *= 2
		groups := engine.get_characters_grouped(query, engine.CHAR_FILTER_ALL_FILLS, .Column_R2L)
		defer engine.groups_delete(&groups)
		count := len(groups.spans)
		for group_index in 0 ..< count {
			for id in engine.group_members(groups, group_index) {
				coord := e.chars.input_coord[id]
				if coord.column < e.canvas.text_left ||
				   coord.column > e.canvas.text_right ||
				   coord.row < e.canvas.text_bottom ||
				   coord.row > e.canvas.text_top {
					continue
				}
				if coord.row <= e.canvas.text_center.row {
					slice_schedule(
						s,
						e,
						slots[:],
						id,
						engine.coord(e.canvas.left - 1, coord.row),
						speed,
					)
				}
			}
			for id in engine.group_members(groups, count - group_index - 1) {
				coord := e.chars.input_coord[id]
				if coord.column < e.canvas.text_left ||
				   coord.column > e.canvas.text_right ||
				   coord.row < e.canvas.text_bottom ||
				   coord.row > e.canvas.text_top {
					continue
				}
				if coord.row > e.canvas.text_center.row {
					slice_schedule(
						s,
						e,
						slots[:],
						id,
						engine.coord(e.canvas.right + 1, coord.row),
						speed,
					)
				}
			}
		}
	case .Diagonal:
		groups := engine.get_characters_grouped(query, engine.CHAR_FILTER_INPUT, .Diagonal_BL2TR)
		defer engine.groups_delete(&groups)
		count := len(groups.spans)
		middle := count / 2
		left_index, right_index := 0, middle
		for left_index < middle || right_index < count {
			if left_index < middle {
				group := engine.group_members(groups, left_index)
				origin := engine.coord(e.chars.input_coord[group[0]].column, e.canvas.bottom - 1)
				for id in group do slice_schedule(s, e, slots[:], id, origin, speed)
				left_index += 1
			}
			if right_index < count {
				group := engine.group_members(groups, right_index)
				origin := engine.coord(
					e.chars.input_coord[group[len(group) - 1]].column,
					e.canvas.top + 1,
				)
				for id in group do slice_schedule(s, e, slots[:], id, origin, speed)
				right_index += 1
			}
		}
	}
	for id in s.render_ids do e.chars.is_visible[id] = true
}

slice_next :: proc(s: ^Slice_State, e: ^engine.Engine) -> ([]engine.Char_Id, bool) {
	if len(s.motion_ids) == 0 do return nil, false
	ids := s.motion_ids[:]
	origins := s.motion_origins[:]
	steps := s.motion_steps[:]
	max_steps := s.motion_max_steps[:]
	input_coords := e.chars.input_coord
	current_coords := e.chars.current_coord
	write := 0
	for read in 0 ..< len(ids) {
		id := ids[read]
		step := steps[read] + 1
		maximum := max_steps[read]
		factor := ease.ease(s.config.movement_easing, f64(step) / f64(maximum))
		current_coords[id] = engine.coord_on_line(origins[read], input_coords[id], factor)
		if step == maximum do continue
		if write != read {
			ids[write] = id
			origins[write] = origins[read]
		}
		steps[write] = step
		max_steps[write] = maximum
		write += 1
	}
	resize(&s.motion_ids, write)
	resize(&s.motion_origins, write)
	resize(&s.motion_steps, write)
	resize(&s.motion_max_steps, write)
	return s.render_ids[:], true
}
