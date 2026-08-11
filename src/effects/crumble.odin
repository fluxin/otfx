package effects

import "../engine"

import "core:fmt"
import "core:math/ease"
import "core:math/rand"

Crumble_Dust_Symbols :: [3]string{"*", ".", ","}

Crumble_Config :: struct {
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

crumble_config_default :: proc() -> Crumble_Config {
	cfg := Crumble_Config {
		final_gradient_direction = .Diagonal,
	}
	append(
		&cfg.final_gradient_stops,
		engine.Color{0x5C, 0xE1, 0xFF},
		engine.Color{0xFF, 0x8C, 0x00},
	)
	append(&cfg.final_gradient_steps, 12)
	return cfg
}

crumble_parse :: proc(cfg: ^Crumble_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown crumble option: ", name)
			return false
		}
	}
	return true
}

Crumble_Phase :: enum {
	Falling,
	Vacuuming,
	Resetting,
}

Crumble_State :: struct {
	config:          Crumble_Config,
	characters:      [dynamic]engine.Char_Id,
	final_colors:    [dynamic]engine.Color,
	weak_colors:     [dynamic]engine.Color,
	dust_colors:     [dynamic]engine.Color,
	weak_bg:         [dynamic]Maybe(engine.Color),
	dust_bg:         [dynamic]Maybe(engine.Color),
	has_dim_fg:      [dynamic]u8,
	fall_starts:     [dynamic]int,
	fall_steps:      [dynamic]int,
	vacuum_starts:   [dynamic]int,
	vacuum_steps:    [dynamic]int,
	reset_steps:     [dynamic]int,
	dust_symbols:    [dynamic]string, // five contiguous symbols per character
	fall_order:      [dynamic]int,
	vacuum_order:    [dynamic]int,
	fall_active:     [dynamic]int,
	vacuum_active:   [dynamic]int,
	next_fall:       int,
	next_vacuum:     int,
	fall_delay:      int,
	min_fall_delay:  int,
	max_fall_delay:  int,
	fall_group_size: int,
	phase:           Crumble_Phase,
	phase_tick:      int,
	reset_max_ticks: int,
	color_handling:  engine.Existing_Color_Handling,
}

crumble_build :: proc(s: ^Crumble_State, e: ^engine.Engine) {
	s.color_handling = e.cfg.existing_color_handling
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
	s.characters = engine.get_characters(query, engine.CHAR_FILTER_INPUT, .Top_Bottom_Left_Right)
	n := len(s.characters)
	s.final_colors = make([dynamic]engine.Color, n)
	s.weak_colors = make([dynamic]engine.Color, n)
	s.dust_colors = make([dynamic]engine.Color, n)
	s.weak_bg = make([dynamic]Maybe(engine.Color), n)
	s.dust_bg = make([dynamic]Maybe(engine.Color), n)
	s.has_dim_fg = make([dynamic]u8, n)
	s.fall_starts = make([dynamic]int, n)
	s.fall_steps = make([dynamic]int, n)
	s.vacuum_starts = make([dynamic]int, n)
	s.vacuum_steps = make([dynamic]int, n)
	s.reset_steps = make([dynamic]int, n)
	s.dust_symbols = make([dynamic]string, n * 5)
	s.fall_order = make([dynamic]int, n)
	s.vacuum_order = make([dynamic]int, n)

	input_coords := e.chars.input_coord
	visual_fg := e.chars.visual
	visible := e.chars.is_visible
	dust_choices := Crumble_Dust_Symbols
	for id, i in s.characters {
		input := input_coords[id]
		final_color := engine.gradient_sample(sampler, spectrum[:], input)
		s.final_colors[i] = final_color
		if s.color_handling == .Dynamic {
			style := e.chars.input_style[id]
			if fg, ok := style.fg.?; ok {
				s.weak_colors[i] = engine.adjust_color_brightness(fg, 0.65)
				s.dust_colors[i] = engine.adjust_color_brightness(fg, 0.55)
				s.has_dim_fg[i] = 1
			} else if style.bg == nil {
				s.weak_colors[i] = engine.adjust_color_brightness(
					engine.Color{0x80, 0x80, 0x80},
					0.65,
				)
				s.dust_colors[i] = engine.adjust_color_brightness(
					engine.Color{0x80, 0x80, 0x80},
					0.55,
				)
				s.has_dim_fg[i] = 1
			}
			if bg, ok := style.bg.?; ok {
				s.weak_bg[i] = engine.adjust_color_brightness(bg, 0.65)
				s.dust_bg[i] = engine.adjust_color_brightness(bg, 0.55)
			}
		} else {
			s.weak_colors[i] = engine.adjust_color_brightness(final_color, 0.65)
			s.dust_colors[i] = engine.adjust_color_brightness(final_color, 0.55)
			s.has_dim_fg[i] = 1
		}
		s.fall_starts[i] = -1
		s.vacuum_starts[i] = -1
		s.fall_steps[i] = max(
			engine.round_half_even(
				engine.line_length(input, engine.coord(input.column, e.canvas.bottom), true) /
				0.65,
			),
			1,
		)
		vacuum_start := engine.coord(input.column, e.canvas.bottom)
		vacuum_end := engine.coord(input.column, e.canvas.top)
		vacuum_control := engine.coord(e.canvas.center_column, e.canvas.center_row)
		s.vacuum_steps[i] = max(
			engine.round_half_even(
				engine.quadratic_bezier_length(vacuum_start, vacuum_control, vacuum_end),
			),
			1,
		)
		s.reset_steps[i] = max(
			engine.round_half_even(engine.line_length(vacuum_end, input, true)),
			1,
		)
		reset_tail := 68
		if s.color_handling == .Dynamic &&
		   e.chars.input_style[id].fg == nil &&
		   e.chars.input_style[id].bg == nil {
			reset_tail = 32
		}
		s.reset_max_ticks = max(s.reset_max_ticks, s.reset_steps[i] + reset_tail)
		for j in 0 ..< 5 do s.dust_symbols[i * 5 + j] = dust_choices[rand.int_max(len(dust_choices))]
		s.fall_order[i] = i
		s.vacuum_order[i] = i
		if s.has_dim_fg[i] != 0 {
			visual_fg[id].fg = s.weak_colors[i]
		} else {
			visual_fg[id].fg = nil
		}
		visual_fg[id].bg = s.weak_bg[i]
		visible[id] = true
	}
	rand.shuffle(s.fall_order[:])
	rand.shuffle(s.vacuum_order[:])
	s.fall_delay, s.min_fall_delay, s.max_fall_delay, s.fall_group_size = 12, 9, 12, 1
	s.phase = .Falling
}

crumble_falling_active :: proc(s: Crumble_State) -> bool {
	if s.next_fall < len(s.fall_order) do return true
	for i in s.fall_active {
		if s.phase_tick - s.fall_starts[i] < 40 + s.fall_steps[i] do return true
	}
	return false
}

crumble_vacuum_active :: proc(s: Crumble_State) -> bool {
	if s.next_vacuum < len(s.vacuum_order) do return true
	for i in s.vacuum_active {
		if s.phase_tick - s.vacuum_starts[i] < s.vacuum_steps[i] do return true
	}
	return false
}

crumble_next :: proc(s: ^Crumble_State, e: ^engine.Engine) -> ([]engine.Char_Id, bool) {
	input_coords := e.chars.input_coord
	current_coords := e.chars.current_coord
	input_symbols := e.chars.input_symbol
	visual_symbols := e.chars.visual
	visual_fg := e.chars.visual

	for {
		switch s.phase {
		case .Falling:
			if !crumble_falling_active(s^) {
				s.phase = .Vacuuming
				s.phase_tick = 0
				continue
			}
			if s.next_fall < len(s.fall_order) {
				if s.fall_delay == 0 {
					count := rand.int_range(1, s.fall_group_size + 1)
					for _ in 0 ..< count {
						if s.next_fall == len(s.fall_order) do break
						i := s.fall_order[s.next_fall]
						s.next_fall += 1
						s.fall_starts[i] = s.phase_tick
						append(&s.fall_active, i)
					}
					s.fall_delay = rand.int_range(s.min_fall_delay, s.max_fall_delay + 1)
					if rand.int_range(1, 11) > 4 {
						s.fall_group_size += 1
						s.min_fall_delay = max(s.min_fall_delay - 1, 0)
						s.max_fall_delay = max(s.max_fall_delay - 1, 0)
					}
				} else {
					s.fall_delay -= 1
				}
			}
			fall_write := 0
			for i in s.fall_active {
				id := s.characters[i]
				start := s.fall_starts[i]
				age := s.phase_tick - start
				if age >= 40 + s.fall_steps[i] do continue
				if age < 40 {
					visual_symbols[id].symbol = input_symbols[id]
					if s.has_dim_fg[i] != 0 {
						visual_fg[id].fg = engine.gradient_between_step(
							s.weak_colors[i],
							s.dust_colors[i],
							9,
							age / 4,
						)
					} else {
						visual_fg[id].fg = nil
					}
					if weak_bg, ok := s.weak_bg[i].?; ok {
						visual_fg[id].bg = engine.gradient_between_step(
							weak_bg,
							s.dust_bg[i].?,
							9,
							age / 4,
						)
					} else {
						visual_fg[id].bg = nil
					}
					s.fall_active[fall_write] = i
					fall_write += 1
					continue
				}
				fall_age := age - 40
				progress := f64(min(fall_age + 1, s.fall_steps[i])) / f64(s.fall_steps[i])
				input := input_coords[id]
				current_coords[id] = engine.coord_on_line(
					input,
					engine.coord(input.column, e.canvas.bottom),
					ease.ease(.Bounce_Out, progress),
				)
				dust_index := min((fall_age * 5) / s.fall_steps[i], 4)
				visual_symbols[id].symbol = s.dust_symbols[i * 5 + dust_index]
				visual_fg[id].fg = s.has_dim_fg[i] != 0 ? s.dust_colors[i] : nil
				visual_fg[id].bg = s.dust_bg[i]
				s.fall_active[fall_write] = i
				fall_write += 1
			}
			resize(&s.fall_active, fall_write)
			s.phase_tick += 1
			return s.characters[:], true

		case .Vacuuming:
			if !crumble_vacuum_active(s^) {
				s.phase = .Resetting
				s.phase_tick = 0
				continue
			}
			for _ in 0 ..< rand.int_range(3, 10) {
				if s.next_vacuum == len(s.vacuum_order) do break
				i := s.vacuum_order[s.next_vacuum]
				s.next_vacuum += 1
				s.vacuum_starts[i] = s.phase_tick
				append(&s.vacuum_active, i)
			}
			vacuum_write := 0
			for i in s.vacuum_active {
				id := s.characters[i]
				start := s.vacuum_starts[i]
				age := s.phase_tick - start
				steps := s.vacuum_steps[i]
				if age >= steps do continue
				progress := f64(min(age + 1, steps)) / f64(steps)
				input := input_coords[id]
				current_coords[id] = engine.coord_on_quadratic_bezier(
					engine.coord(input.column, e.canvas.bottom),
					engine.coord(e.canvas.center_column, e.canvas.center_row),
					engine.coord(input.column, e.canvas.top),
					ease.ease(.Quintic_Out, progress),
				)
				s.vacuum_active[vacuum_write] = i
				vacuum_write += 1
			}
			resize(&s.vacuum_active, vacuum_write)
			s.phase_tick += 1
			return s.characters[:], true

		case .Resetting:
			if s.phase_tick == s.reset_max_ticks do return nil, false
			for id, i in s.characters {
				input := input_coords[id]
				steps := s.reset_steps[i]
				if s.phase_tick < steps {
					current_coords[id] = engine.coord_on_line(
						engine.coord(input.column, e.canvas.top),
						input,
						f64(s.phase_tick + 1) / f64(steps),
					)
					visual_symbols[id].symbol = input_symbols[id]
					visual_fg[id].fg = s.has_dim_fg[i] != 0 ? s.dust_colors[i] : nil
					visual_fg[id].bg = s.dust_bg[i]
					continue
				}
				flash_age := s.phase_tick - steps
				visual_symbols[id].symbol = input_symbols[id]
				if flash_age < 28 {
					if s.color_handling == .Dynamic {
						style := e.chars.input_style[id]
						if s.has_dim_fg[i] != 0 {
							start := style.fg != nil ? style.fg.? : engine.Color{0x80, 0x80, 0x80}
							visual_fg[id].fg = engine.gradient_between_step(
								start,
								engine.Color{0xFF, 0xFF, 0xFF},
								6,
								flash_age / 4,
							)
						} else {
							visual_fg[id].fg = nil
						}
						if bg, ok := style.bg.?; ok {
							visual_fg[id].bg = engine.gradient_between_step(
								bg,
								engine.Color{0xFF, 0xFF, 0xFF},
								6,
								flash_age / 4,
							)
						} else {
							visual_fg[id].bg = nil
						}
					} else {
						visual_fg[id].fg = engine.gradient_between_step(
							s.final_colors[i],
							engine.Color{0xFF, 0xFF, 0xFF},
							6,
							flash_age / 4,
						)
					}
				} else {
					if s.color_handling == .Dynamic {
						style := e.chars.input_style[id]
						if style.fg == nil && style.bg == nil {
							visual_fg[id].fg = nil
							visual_fg[id].bg = nil
						} else {
							engine.dynamic_gradient_to_input(
								&visual_fg[id],
								engine.Color{0xFF, 0xFF, 0xFF},
								style,
								9,
								min((flash_age - 28) / 4, 9),
							)
						}
					} else {
						visual_fg[id].fg = engine.gradient_between_step(
							engine.Color{0xFF, 0xFF, 0xFF},
							s.final_colors[i],
							9,
							min((flash_age - 28) / 4, 9),
						)
					}
				}
			}
			s.phase_tick += 1
			return s.characters[:], true
		}
	}
}
