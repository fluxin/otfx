package effects

import engine "../engine"

import "core:fmt"
import ease "core:math/ease"
import rand "core:math/rand"

Bubbles_Pop_Condition :: enum {
	Row,
	Bottom,
	Anywhere,
}

Bubbles_Bubble_State :: enum u8 {
	Pending,
	Float,
	Pop,
	Done,
}

bubbles_pop_condition_parse :: proc(s: string) -> (Bubbles_Pop_Condition, bool) {
	switch s {
	case "row":
		return .Row, true
	case "bottom":
		return .Bottom, true
	case "anywhere":
		return .Anywhere, true
	}
	return .Row, false
}

Bubbles_Config :: struct {
	rainbow:                  bool,
	bubble_colors:            [dynamic]engine.Color,
	pop_color:                engine.Color,
	bubble_speed:             f64,
	bubble_delay:             int,
	pop_condition:            Bubbles_Pop_Condition,
	movement_easing:          ease.Ease,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

bubbles_config_default :: proc() -> Bubbles_Config {
	cfg := Bubbles_Config {
		pop_color                = engine.Color{0xFF, 0xFF, 0xFF},
		bubble_speed             = 0.5,
		bubble_delay             = 20,
		movement_easing          = .Sine_In_Out,
		final_gradient_direction = .Diagonal,
	}
	append(
		&cfg.bubble_colors,
		..[]engine.Color {
			engine.Color{0xD3, 0x3A, 0xFF},
			engine.Color{0x73, 0x95, 0xC4},
			engine.Color{0x43, 0xC2, 0xA7},
			engine.Color{0x02, 0xFF, 0x7F},
		},
	)
	append(
		&cfg.final_gradient_stops,
		engine.Color{0xD3, 0x3A, 0xFF},
		engine.Color{0x02, 0xFF, 0x7F},
	)
	append(&cfg.final_gradient_steps, 12)
	return cfg
}

bubbles_parse :: proc(cfg: ^Bubbles_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--rainbow":
			cfg.rainbow = true
		case "--bubble-colors":
			if !parse_colors_flag(&cfg.bubble_colors, args, &i, value, has_value) do return false
		case "--pop-color":
			if !parse_color_flag(&cfg.pop_color, args, &i, value, has_value) do return false
		case "--bubble-speed":
			if !parse_float_flag(&cfg.bubble_speed, args, &i, value, has_value) || cfg.bubble_speed <= 0 do return false
		case "--bubble-delay":
			if !parse_int_flag(&cfg.bubble_delay, args, &i, value, has_value) || cfg.bubble_delay <= 0 do return false
		case "--pop-condition":
			v, ok := opt_value(args, &i, value, has_value)
			if !ok do return false
			condition, valid := bubbles_pop_condition_parse(v)
			if !valid do return false
			cfg.pop_condition = condition
		case "--movement-easing":
			if !parse_ease_flag(&cfg.movement_easing, args, &i, value, has_value) do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown bubbles option: ", name)
			return false
		}
	}
	return true
}

Bubbles_State :: struct {
	config:          Bubbles_Config,
	characters:      [dynamic]engine.Char_Id,
	final_colors:    [dynamic]engine.Color, // Char_Id indexed
	circle_dx:       [dynamic]int, // Char_Id indexed
	circle_dy:       [dynamic]int,
	color_offsets:   [dynamic]int,
	pop_targets:     [dynamic]engine.Coord,
	pop_steps:       [dynamic]int,
	bubbles:         engine.Char_Groups,
	bubble_origins:  [dynamic]engine.Coord,
	bubble_targets:  [dynamic]engine.Coord,
	bubble_steps:    [dynamic]int,
	bubble_radii:    [dynamic]int,
	bubble_colors:   [dynamic]engine.Color,
	bubble_states:   [dynamic]Bubbles_Bubble_State,
	bubble_starts:   [dynamic]int,
	pop_starts:      [dynamic]int,
	next_bubble:     int,
	delay:           int,
	rainbow_palette: [dynamic]engine.Color,
	rainbow_index:   int,
	tick:            int,
}

bubbles_build :: proc(s: ^Bubbles_State, e: ^engine.Engine) {
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
	s.final_colors = make([dynamic]engine.Color, len(e.chars))
	s.circle_dx = make([dynamic]int, len(e.chars))
	s.circle_dy = make([dynamic]int, len(e.chars))
	s.color_offsets = make([dynamic]int, len(e.chars))
	s.pop_targets = make([dynamic]engine.Coord, len(e.chars))
	s.pop_steps = make([dynamic]int, len(e.chars))
	input_coords := e.chars.input_coord
	visible := e.chars.is_visible
	for id in s.characters {
		s.final_colors[id] = engine.gradient_sample(
			final_sampler,
			final_spectrum[:],
			input_coords[id],
		)
		visible[id] = false
	}

	rows := engine.get_characters_grouped(query, engine.CHAR_FILTER_INPUT, .Row_B2T)
	defer engine.groups_delete(&rows)
	read := 0
	for read < len(rows.members) {
		remaining := len(rows.members) - read
		count := remaining < 5 ? remaining : rand.int_range(5, min(remaining, 20) + 1)
		start := len(s.bubbles.members)
		append(&s.bubbles.members, ..rows.members[read:read + count])
		append(&s.bubbles.spans, engine.Span{start, count})
		read += count
	}
	bubble_count := len(s.bubbles.spans)
	s.bubble_origins = make([dynamic]engine.Coord, bubble_count)
	s.bubble_targets = make([dynamic]engine.Coord, bubble_count)
	s.bubble_steps = make([dynamic]int, bubble_count)
	s.bubble_radii = make([dynamic]int, bubble_count)
	s.bubble_colors = make([dynamic]engine.Color, bubble_count)
	s.bubble_states = make([dynamic]Bubbles_Bubble_State, bubble_count)
	s.bubble_starts = make([dynamic]int, bubble_count)
	s.pop_starts = make([dynamic]int, bubble_count)
	for bi in 0 ..< bubble_count {
		members := engine.group_members(s.bubbles, bi)
		radius := max(len(members) / 5, 1)
		lowest := e.canvas.bottom
		if s.config.pop_condition == .Row {
			lowest = input_coords[members[0]].row
			for id in members do lowest = min(lowest, input_coords[id].row)
		}
		origin := engine.coord(
			rand.int_range(e.canvas.left, e.canvas.right + 1),
			e.canvas.top + 10,
		)
		target := engine.coord(rand.int_range(e.canvas.left, e.canvas.right + 1), lowest)
		s.bubble_origins[bi] = origin
		s.bubble_targets[bi] = target
		s.bubble_steps[bi] = max(
			engine.round_half_even(
				engine.line_length(origin, target, true) / s.config.bubble_speed,
			),
			1,
		)
		s.bubble_radii[bi] = radius
		s.bubble_colors[bi] = s.config.bubble_colors[rand.int_max(len(s.config.bubble_colors))]
		circle_points := engine.find_coords_on_circle(
			engine.coord(0, 0),
			radius,
			len(members),
			false,
		)
		palette_offset := 0
		for id, point in members {
			s.circle_dx[id] = circle_points[point].column
			s.circle_dy[id] = circle_points[point].row
			s.color_offsets[id] = palette_offset
			palette_offset += 2
		}
		delete(circle_points[:])
	}
	if s.config.rainbow {
		s.rainbow_palette = engine.gradient_make(
			[]engine.Color {
				engine.Color{0xE8, 0x14, 0x16},
				engine.Color{0xFF, 0xA5, 0x00},
				engine.Color{0xFA, 0xEB, 0x36},
				engine.Color{0x79, 0xC3, 0x14},
				engine.Color{0x48, 0x7D, 0xE7},
				engine.Color{0x4B, 0x36, 0x9D},
				engine.Color{0x70, 0x36, 0x9D},
			},
			[]int{5},
			false,
		)
		for id in s.characters {
			for s.color_offsets[id] >= len(s.rainbow_palette) do s.color_offsets[id] -= len(s.rainbow_palette)
		}
	}
}

bubbles_next :: proc(s: ^Bubbles_State, e: ^engine.Engine) -> ([]engine.Char_Id, bool) {
	active := s.next_bubble < len(s.bubbles.spans)
	for state in s.bubble_states {
		if state == .Float || state == .Pop {
			active = true
			break
		}
	}
	if !active do return nil, false
	if s.next_bubble < len(s.bubbles.spans) {
		if s.delay == 0 {
			bi := s.next_bubble
			s.next_bubble += 1
			s.bubble_states[bi] = .Float
			s.bubble_starts[bi] = s.tick
			s.delay = s.config.bubble_delay
		} else {
			s.delay -= 1
		}
	}

	current_coords := e.chars.current_coord
	input_coords := e.chars.input_coord
	input_symbols := e.chars.input_symbol
	visual_symbols := e.chars.visual
	visual_fg := e.chars.visual
	visible := e.chars.is_visible
	for bi in 0 ..< len(s.bubble_states) {
		state := s.bubble_states[bi]
		if state == .Pending || state == .Done do continue
		members := engine.group_members(s.bubbles, bi)
		if state == .Float {
			age := s.tick - s.bubble_starts[bi]
			steps := s.bubble_steps[bi]
			progress := f64(min(age + 1, steps)) / f64(steps)
			anchor := engine.coord_on_line(s.bubble_origins[bi], s.bubble_targets[bi], progress)
			for id in members {
				current_coords[id] = engine.coord(
					anchor.column + s.circle_dx[id],
					anchor.row + s.circle_dy[id],
				)
				visual_symbols[id].symbol = input_symbols[id]
				if s.config.rainbow {
					color_index := s.color_offsets[id] + s.rainbow_index
					if color_index >= len(s.rainbow_palette) do color_index -= len(s.rainbow_palette)
					visual_fg[id].fg = s.rainbow_palette[color_index]
				} else {
					visual_fg[id].fg = s.bubble_colors[bi]
				}
				visible[id] = true
			}
			if age >= steps || (s.config.pop_condition == .Anywhere && rand.float64() < 0.002) {
				s.bubble_states[bi] = .Pop
				s.pop_starts[bi] = s.tick
				for id in members {
					p := current_coords[id]
					s.pop_targets[id] = engine.coord(
						p.column + 3 * s.circle_dx[id],
						p.row + 3 * s.circle_dy[id],
					)
					s.pop_steps[id] = max(
						engine.round_half_even(
							engine.line_length(s.pop_targets[id], input_coords[id], true) / 0.3,
						),
						1,
					)
				}
			}
		} else {
			age := s.tick - s.pop_starts[bi]
			max_steps := 0
			for id in members do max_steps = max(max_steps, s.pop_steps[id])
			for id in members {
				if age < 18 {
					current_coords[id] = s.pop_targets[id]
					visual_symbols[id].symbol = age < 9 ? "*" : "'"
					visual_fg[id].fg = s.config.pop_color
				} else {
					move_age := age - 18
					steps := s.pop_steps[id]
					if move_age < steps {
						current_coords[id] = engine.coord_on_line(
							s.pop_targets[id],
							input_coords[id],
							ease.ease(s.config.movement_easing, f64(move_age + 1) / f64(steps)),
						)
					}
					visual_symbols[id].symbol = input_symbols[id]
					visual_fg[id].fg = engine.gradient_between_step(
						s.config.pop_color,
						s.final_colors[id],
						8,
						min(move_age / 6, 8),
					)
				}
			}
			if age >= 18 + max(max_steps, 54) do s.bubble_states[bi] = .Done
		}
	}
	if s.config.rainbow {
		s.rainbow_index += 1
		if s.rainbow_index == len(s.rainbow_palette) do s.rainbow_index = 0
	}
	s.tick += 1
	return s.characters[:], true
}
