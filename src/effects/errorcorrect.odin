package effects

import engine "../engine"
import "core:fmt"
import rand "core:math/rand"

Errorcorrect_Config :: struct {
	error_pairs:              f64,
	swap_delay:               int,
	error_color:              engine.Color,
	correct_color:            engine.Color,
	movement_speed:           f64,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

errorcorrect_config_default :: proc() -> Errorcorrect_Config {
	cfg := Errorcorrect_Config {
		error_pairs              = 0.1,
		swap_delay               = 6,
		error_color              = {0xe7, 0x4c, 0x3c},
		correct_color            = {0x45, 0xbf, 0x55},
		movement_speed           = 0.9,
		final_gradient_direction = .Vertical,
	}
	append(
		&cfg.final_gradient_stops,
		..[]engine.Color{{0x8A, 0x00, 0x8A}, {0x00, 0xD1, 0xFF}, {0xFF, 0xFF, 0xFF}},
	)
	append(&cfg.final_gradient_steps, 12)
	return cfg
}

errorcorrect_parse :: proc(cfg: ^Errorcorrect_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--error-pairs":
			if !parse_float_flag(&cfg.error_pairs, args, &i, value, has_value) || cfg.error_pairs <= 0 do return false
		case "--swap-delay":
			if !parse_int_flag(&cfg.swap_delay, args, &i, value, has_value) || cfg.swap_delay <= 0 do return false
		case "--error-color":
			if !parse_color_flag(&cfg.error_color, args, &i, value, has_value) do return false
		case "--correct-color":
			if !parse_color_flag(&cfg.correct_color, args, &i, value, has_value) do return false
		case "--movement-speed":
			if !parse_float_flag(&cfg.movement_speed, args, &i, value, has_value) || cfg.movement_speed <= 0 do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown errorcorrect option: ", name); return false
		}
	}
	return true
}

Errorcorrect_Pair :: struct {
	first, second: engine.Char_Id,
}

// One flat active-id column; each id's phase is derived from its start tick.
Errorcorrect_State :: struct {
	config:       Errorcorrect_Config,
	swapped:      [dynamic]Errorcorrect_Pair,
	swapped_head: int,
	final_colors: [dynamic]engine.Color,
	origins:      [dynamic]engine.Coord,
	max_steps:    [dynamic]int,
	start_ticks:  [dynamic]int,
	active:       [dynamic]engine.Char_Id,
	swap_delay:   int,
	tick:         int,
}

errorcorrect_build :: proc(s: ^Errorcorrect_State, e: ^engine.Engine) {
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
	characters := engine.get_characters(
		engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas},
		engine.CHAR_FILTER_INPUT,
		.Top_Bottom_Left_Right,
	)
	defer delete(characters[:])
	s.final_colors = make([dynamic]engine.Color, len(e.chars))
	s.origins = make([dynamic]engine.Coord, len(e.chars))
	s.max_steps = make([dynamic]int, len(e.chars))
	s.start_ticks = make([dynamic]int, len(e.chars))
	for i in 0 ..< len(s.start_ticks) do s.start_ticks[i] = -1
	for id in characters {
		s.final_colors[id] = engine.gradient_sample(sampler, spectrum[:], e.chars.input_coord[id])
		e.chars.visual[id].symbol = e.chars.input_symbol[id]
		e.chars.visual[id].fg = s.final_colors[id]
		e.chars.is_visible[id] = true
	}
	available := make([dynamic]engine.Char_Id, 0, len(characters), context.temp_allocator)
	append(&available, ..characters[:])
	for _ in 0 ..< int(s.config.error_pairs * f64(len(characters))) {
		if len(available) < 2 do break
		first_index := rand.int_max(
			len(available),
		); first := available[first_index]; ordered_remove(&available, first_index)
		second_index := rand.int_max(
			len(available),
		); second := available[second_index]; ordered_remove(&available, second_index)
		first_home, second_home := e.chars.input_coord[first], e.chars.input_coord[second]
		s.origins[first], s.origins[second] = second_home, first_home
		e.chars.current_coord[first], e.chars.current_coord[second] = second_home, first_home
		s.max_steps[first] = max(
			engine.round_half_even(
				engine.line_length(second_home, first_home, true) / s.config.movement_speed,
			),
			1,
		)
		s.max_steps[second] = max(
			engine.round_half_even(
				engine.line_length(first_home, second_home, true) / s.config.movement_speed,
			),
			1,
		)
		append(&s.swapped, Errorcorrect_Pair{first, second})
	}
}

errorcorrect_next :: proc(s: ^Errorcorrect_State, e: ^engine.Engine) -> bool {
	if s.swapped_head < len(s.swapped) && s.swap_delay == 0 {
		pair := s.swapped[s.swapped_head]; s.swapped_head += 1
		s.start_ticks[pair.first] = s.tick
		s.start_ticks[pair.second] = s.tick
		append(&s.active, pair.first, pair.second)
		s.swap_delay = s.config.swap_delay
	} else if s.swap_delay != 0 do s.swap_delay -= 1
	if len(s.active) == 0 do return false
	first_wipe := [8]string{"▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"}
	last_wipe := [7]string{"▇", "▆", "▅", "▄", "▃", "▂", "▁"}
	white := engine.Color{0xff, 0xff, 0xff}
	write := 0
	for id in s.active {
		age, motion_start := s.tick - s.start_ticks[id], 84
		last_start := motion_start + s.max_steps[id] - 1
		total := s.max_steps[id] + 137
		if age >= total do continue
		switch {
		case age < 60:
			if (age / 3) % 2 ==
			   0 {e.chars.visual[id].symbol = "▓"; e.chars.visual[id].fg = s.config.error_color} else {e.chars.visual[id].symbol = e.chars.input_symbol[id]; e.chars.visual[id].fg = white}
		case age < 84:
			e.chars.visual[id].symbol = first_wipe[(age - 60) / 3]
			e.chars.visual[id].fg = s.config.error_color
		case age < last_start:
			progress := f64(age - motion_start + 1) / f64(s.max_steps[id])
			e.chars.current_coord[id] = engine.coord_on_line(
				s.origins[id],
				e.chars.input_coord[id],
				progress,
			)
			e.chars.layer[id] = 1
			e.chars.visual[id].symbol = "█"
			e.chars.visual[id].fg = engine.gradient_between_step(
				s.config.error_color,
				s.config.correct_color,
				10,
				min(engine.round_half_even(progress * 10), 10),
			)
		case age < last_start + 21:
			e.chars.current_coord[id] = e.chars.input_coord[id]
			e.chars.layer[id] = 0
			e.chars.visual[id].symbol = last_wipe[(age - last_start) / 3]
			e.chars.visual[id].fg = s.config.correct_color
		case:
			e.chars.visual[id].symbol = e.chars.input_symbol[id]
			e.chars.visual[id].fg = engine.gradient_between_step(
				s.config.correct_color,
				s.final_colors[id],
				10,
				min((age - last_start - 21) / 3, 10),
			)
		}
		s.active[write] = id; write += 1
	}
	resize(&s.active, write)
	s.tick += 1
	engine.frame(e)
	return true
}
