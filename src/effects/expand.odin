package effects

import engine "../engine"

import "core:fmt"

// expand — all characters start at the canvas center and fly home.

Expand_Config :: struct {
	expand_easing:            engine.Easing,
	movement_speed:           f64,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

expand_config_default :: proc() -> Expand_Config {
	cfg := Expand_Config {
		expand_easing            = engine.ease_of(.Quartic_In_Out),
		movement_speed           = 0.35,
		final_gradient_direction = .Vertical,
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

expand_parse :: proc(cfg: ^Expand_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--expand-easing":
			if !parse_ease_flag(&cfg.expand_easing, args, &i, value, has_value) do return false
		case "--movement-speed":
			if !parse_float_flag(&cfg.movement_speed, args, &i, value, has_value) do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown expand option: ", name)
			return false
		}
	}
	return true
}

Expand_State :: struct {
	config:       Expand_Config,
	characters:   [dynamic]engine.Char_Id,
	final_colors: [dynamic]engine.Color,
	max_steps:    [dynamic]int,
	step_limit:   int,
	tick:         int,
}

expand_build :: proc(s: ^Expand_State, e: ^engine.Engine) {
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
		engine.filter_input(),
		.Top_Bottom_Left_Right,
	)
	n := len(s.characters)
	s.final_colors = make([dynamic]engine.Color, n)
	s.max_steps = make([dynamic]int, n)

	for id, i in s.characters {
		c := e.chars.input_coord[id]
		s.final_colors[i] = engine.gradient_sample(sampler, spectrum[:], c)
		e.chars.current_coord[id] = e.canvas.center
		s.max_steps[i] = max(
			engine.round_half_even(
				engine.line_length(e.canvas.center, c, true) / s.config.movement_speed,
			),
			1,
		)
		s.step_limit = max(s.step_limit, s.max_steps[i])
		e.chars.is_visible[id] = true
		e.chars.layer[id] = 1
	}
}

expand_next :: proc(s: ^Expand_State, e: ^engine.Engine) -> bool {
	if s.tick == s.step_limit do return false
	for id, i in s.characters {
		maximum := s.max_steps[i]
		progress := f64(min(s.tick + 1, maximum)) / f64(maximum)
		factor := engine.easing_apply(s.config.expand_easing, progress)
		e.chars.current_coord[id] = engine.coord_on_line(
			e.canvas.center,
			e.chars.input_coord[id],
			factor,
		)
		e.chars.visual_fg[id] = engine.gradient_between_step(
			s.config.final_gradient_stops[0],
			s.final_colors[i],
			10,
			min(engine.round_half_even(factor * 10), 10),
		)
		if s.tick + 1 >= maximum {
			e.chars.current_coord[id] = e.chars.input_coord[id]
			e.chars.visual_fg[id] = s.final_colors[i]
			e.chars.layer[id] = 0
		}
	}
	s.tick += 1
	engine.frame(e, s.characters[:])
	return true
}
