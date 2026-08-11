package effects

import engine "../engine"

import "core:fmt"
import rand "core:math/rand"

Bouncyballs_Config :: struct {
	ball_colors:              [dynamic]engine.Color,
	ball_symbols:             [dynamic]string,
	ball_delay:               int,
	movement_speed:           f64,
	movement_easing:          engine.Easing,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

bouncyballs_config_default :: proc() -> Bouncyballs_Config {
	cfg := Bouncyballs_Config {
		ball_delay               = 4,
		movement_speed           = 0.45,
		movement_easing          = engine.ease_of(.Bounce_Out),
		final_gradient_direction = .Diagonal,
	}
	append(
		&cfg.ball_colors,
		..[]engine.Color {
			engine.Color{0xd1, 0xf4, 0xa5},
			engine.Color{0x96, 0xe2, 0xa4},
			engine.Color{0x5a, 0xcd, 0xa9},
		},
	)
	append(&cfg.ball_symbols, ..[]string{"*", "o", "O", "0", "."})
	append(
		&cfg.final_gradient_stops,
		..[]engine.Color{engine.Color{0xf8, 0xff, 0xae}, engine.Color{0x43, 0xc6, 0xac}},
	)
	append(&cfg.final_gradient_steps, 12)
	return cfg
}

bouncyballs_parse :: proc(cfg: ^Bouncyballs_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--ball-colors":
			if !parse_colors_flag(&cfg.ball_colors, args, &i, value, has_value) do return false
		case "--ball-symbols":
			if !parse_symbols_flag(&cfg.ball_symbols, args, &i, value, has_value) do return false
		case "--ball-delay":
			if !parse_int_flag(&cfg.ball_delay, args, &i, value, has_value) || cfg.ball_delay < 0 do return false
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
			fmt.eprintln("Error: unknown bouncyballs option: ", name)
			return false
		}
	}
	return true
}

Bouncyballs_State :: struct {
	config:       Bouncyballs_Config,
	characters:   [dynamic]engine.Char_Id,
	index_by_id:  [dynamic]int,
	final_colors: [dynamic]engine.Color,
	ball_colors:  [dynamic]engine.Color,
	ball_symbols: [dynamic]string,
	origins:      [dynamic]engine.Coord,
	max_steps:    [dynamic]int,
	start_ticks:  [dynamic]int,
	row_groups:   engine.Char_Groups,
	next_group:   int,
	pending:      [dynamic]engine.Char_Id,
	active_slots: [dynamic]int,
	ball_delay:   int,
	tick:         int,
}

bouncyballs_build :: proc(s: ^Bouncyballs_State, e: ^engine.Engine) {
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
	s.characters = engine.get_characters(query, engine.filter_input(), .Top_Bottom_Left_Right)
	s.row_groups = engine.get_characters_grouped(query, engine.filter_input(), .Row_B2T)
	n := len(s.characters)
	s.index_by_id = make([dynamic]int, len(e.chars))
	s.final_colors = make([dynamic]engine.Color, n)
	s.ball_colors = make([dynamic]engine.Color, n)
	s.ball_symbols = make([dynamic]string, n)
	s.origins = make([dynamic]engine.Coord, n)
	s.max_steps = make([dynamic]int, n)
	s.start_ticks = make([dynamic]int, n)

	for id, i in s.characters {
		s.index_by_id[id] = i
		input_coord := e.chars.input_coord[id]
		s.ball_colors[i] = s.config.ball_colors[rand.int_max(len(s.config.ball_colors))]
		s.ball_symbols[i] = s.config.ball_symbols[rand.int_max(len(s.config.ball_symbols))]
		s.final_colors[i] = engine.gradient_sample(sampler, spectrum[:], input_coord)
		drop_row := int(f64(e.canvas.top) * rand.float64_range(1, 1.5))
		s.origins[i] = engine.coord(input_coord.column, drop_row)
		e.chars.current_coord[id] = s.origins[i]
		s.max_steps[i] = max(
			engine.round_half_even(
				engine.line_length(s.origins[i], input_coord, true) / s.config.movement_speed,
			),
			1,
		)
		s.start_ticks[i] = -1
	}
}

bouncyballs_next :: proc(s: ^Bouncyballs_State, e: ^engine.Engine) -> bool {
	active :=
		s.next_group < engine.group_count(s.row_groups) ||
		len(s.pending) > 0 ||
		len(s.active_slots) > 0
	if !active do return false
	if len(s.pending) == 0 && s.next_group < engine.group_count(s.row_groups) {
		append(&s.pending, ..engine.group_slice(s.row_groups, s.next_group))
		s.next_group += 1
	}
	if len(s.pending) > 0 {
		if s.ball_delay == 0 {
			for _ in 0 ..< rand.int_range(2, 7) {
				if len(s.pending) == 0 do break
				index := rand.int_max(len(s.pending))
				id := s.pending[index]
				ordered_remove(&s.pending, index)
				slot := s.index_by_id[id]
				s.start_ticks[slot] = s.tick
				append(&s.active_slots, slot)
				e.chars.is_visible[id] = true
			}
			s.ball_delay = s.config.ball_delay
		} else {
			s.ball_delay -= 1
		}
	}
	write := 0
	for slot in s.active_slots {
		id := s.characters[slot]
		age := s.tick - s.start_ticks[slot]
		if age >= s.max_steps[slot] + 65 do continue
		if age < s.max_steps[slot] - 1 {
			progress := f64(age + 1) / f64(s.max_steps[slot])
			e.chars.current_coord[id] = engine.coord_on_line(
				s.origins[slot],
				e.chars.input_coord[id],
				engine.easing_apply(s.config.movement_easing, progress),
			)
			e.chars.visual_symbol[id] = s.ball_symbols[slot]
			e.chars.visual_fg[id] = s.ball_colors[slot]
		} else {
			e.chars.current_coord[id] = e.chars.input_coord[id]
			e.chars.visual_symbol[id] = e.chars.input_symbol[id]
			fade_tick := age - (s.max_steps[slot] - 1)
			e.chars.visual_fg[id] = engine.gradient_between_step(
				s.ball_colors[slot],
				s.final_colors[slot],
				10,
				min(fade_tick / 6, 10),
			)
		}
		if age + 1 < s.max_steps[slot] + 65 {
			s.active_slots[write] = slot
			write += 1
		}
	}
	resize(&s.active_slots, write)
	s.tick += 1
	engine.frame(e, s.characters[:])
	return true
}
