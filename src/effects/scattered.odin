package effects

import engine "../engine"

import "core:fmt"
import ease "core:math/ease"

// scattered — characters fly in from random coordinates with a slight
// overshoot easing, synced to movement distance.

Scattered_Config :: struct {
	movement_speed:           f64,
	movement_easing:          ease.Ease,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_frames:    int,
	final_gradient_direction: engine.Gradient_Direction,
}

scattered_config_default :: proc() -> Scattered_Config {
	cfg := Scattered_Config {
		movement_speed           = 0.5,
		movement_easing          = .Back_In_Out,
		final_gradient_frames    = 9,
		final_gradient_direction = .Vertical,
	}
	append(
		&cfg.final_gradient_stops,
		..[]engine.Color {
			engine.Color{0xff, 0x90, 0x48},
			engine.Color{0xab, 0x9d, 0xff},
			engine.Color{0xbd, 0xff, 0xea},
		},
	)
	append(&cfg.final_gradient_steps, 12)
	return cfg
}

scattered_parse :: proc(cfg: ^Scattered_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--movement-speed":
			if !parse_float_flag(&cfg.movement_speed, args, &i, value, has_value) do return false
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
			fmt.eprintln("Error: unknown scattered option: ", name)
			return false
		}
	}
	return true
}

Scattered_State :: struct {
	config:       Scattered_Config,
	characters:   [dynamic]engine.Char_Id,
	final_colors: [dynamic]engine.Color,
	origins:      [dynamic]engine.Coord,
	max_steps:    [dynamic]int,
	step_limit:   int,
	tick:         int,
	initial_hold: int,
}

scattered_build :: proc(s: ^Scattered_State, e: ^engine.Engine) {
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
	s.final_colors = make([dynamic]engine.Color, n)
	s.origins = make([dynamic]engine.Coord, n)
	s.max_steps = make([dynamic]int, n)
	for id, i in s.characters {
		c := e.chars.input_coord[id]
		s.final_colors[i] = engine.gradient_sample(sampler, spectrum[:], c)

		start :=
			e.canvas.right < 2 || e.canvas.top < 2 ? engine.coord(1, 1) : engine.canvas_random_coord(e.canvas, false, false)
		e.chars.current_coord[id] = start
		s.origins[i] = start
		s.max_steps[i] = max(
			engine.round_half_even(engine.line_length(start, c, true) / s.config.movement_speed),
			1,
		)
		s.step_limit = max(s.step_limit, s.max_steps[i])
		e.chars.layer[id] = 1
		engine.character_set_visual(
			&e.chars,
			id,
			{symbol = e.chars.input_symbol[id], fg = spectrum[0]},
		)
		e.chars.is_visible[id] = true
	}
	s.initial_hold = 25
}

scattered_next :: proc(s: ^Scattered_State, e: ^engine.Engine) -> bool {
	if s.tick == s.step_limit do return false
	if s.initial_hold > 0 {
		s.initial_hold -= 1
		engine.frame(e, s.characters[:])
		return true
	}
	for id, i in s.characters {
		steps := s.max_steps[i]
		progress := f64(min(s.tick + 1, steps)) / f64(steps)
		e.chars.current_coord[id] = engine.coord_on_line(
			s.origins[i],
			e.chars.input_coord[id],
			ease.ease(s.config.movement_easing, progress),
		)
		e.chars.visual[id].fg = engine.gradient_between_step(
			s.config.final_gradient_stops[0],
			s.final_colors[i],
			10,
			min(engine.round_half_even(progress * 9), 10),
		)
		if s.tick + 1 >= steps {
			e.chars.current_coord[id] = e.chars.input_coord[id]
			e.chars.visual[id].fg = s.final_colors[i]
			e.chars.layer[id] = 0
		}
	}
	s.tick += 1
	engine.frame(e, s.characters[:])
	return true
}
