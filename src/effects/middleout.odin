package effects

import engine "../engine"

import "core:fmt"

// middleout — characters condense onto the middle row/column, then expand to
// their home coordinates.

Expand_Direction :: enum {
	Vertical,
	Horizontal,
}

Middleout_Config :: struct {
	starting_color:           engine.Color,
	expand_direction:         Expand_Direction,
	center_movement_speed:    f64,
	full_movement_speed:      f64,
	center_easing:            engine.Easing,
	full_easing:              engine.Easing,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

middleout_config_default :: proc() -> Middleout_Config {
	cfg := Middleout_Config {
		starting_color           = engine.Color{0xff, 0xff, 0xff},
		expand_direction         = .Vertical,
		center_movement_speed    = 0.6,
		full_movement_speed      = 0.6,
		center_easing            = engine.ease_of(.Sine_In_Out),
		full_easing              = engine.ease_of(.Sine_In_Out),
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

middleout_parse :: proc(cfg: ^Middleout_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--starting-color":
			if !parse_color_flag(&cfg.starting_color, args, &i, value, has_value) do return false
		case "--expand-direction":
			v, ok := opt_value(args, &i, value, has_value)
			if !ok do return false
			switch v {
			case "vertical":
				cfg.expand_direction = .Vertical
			case "horizontal":
				cfg.expand_direction = .Horizontal
			case:
				return false
			}
		case "--center-movement-speed":
			if !parse_float_flag(&cfg.center_movement_speed, args, &i, value, has_value) do return false
		case "--full-movement-speed":
			if !parse_float_flag(&cfg.full_movement_speed, args, &i, value, has_value) do return false
		case "--center-easing":
			if !parse_ease_flag(&cfg.center_easing, args, &i, value, has_value) do return false
		case "--full-easing":
			if !parse_ease_flag(&cfg.full_easing, args, &i, value, has_value) do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown middleout option: ", name)
			return false
		}
	}
	return true
}

Middleout_State :: struct {
	config:       Middleout_Config,
	final_colors: [dynamic]engine.Color_Pair,
	center_paths: [dynamic]int,
	full_paths:   [dynamic]int,
	full_scenes:  [dynamic]int,
	phase_full:   bool,
}

middleout_build :: proc(s: ^Middleout_State, e: ^engine.Engine) {
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
	s.center_paths = make([dynamic]int, max_slot + 1)
	s.full_paths = make([dynamic]int, max_slot + 1)
	s.full_scenes = make([dynamic]int, max_slot + 1)
	for i in 0 ..= max_slot do s.center_paths[i], s.full_paths[i], s.full_scenes[i] = -1, -1, -1

	for id in chars {
		c := e.chars.input_coord[id]
		final := engine.Color_Pair {
			fg = engine.gradient_sample(sampler, spectrum[:], c),
			bg = nil,
		}
		s.final_colors[id] = final

		e.chars.current_coord[id] = e.canvas.center

		// center path: to the middle row/column
		mid := engine.coord(c.column, e.canvas.center_row)
		if s.config.expand_direction == .Horizontal do mid = engine.coord(e.canvas.center_column, c.row)
		cp := engine.new_path(
			e,
			s.config.center_movement_speed,
			s.config.center_easing,
			nil,
			0,
			false,
		)
		engine.path_add_waypoint(&e.paths[cp], mid)
		s.center_paths[id] = cp

		// full path: to home
		fp := engine.new_path(e, s.config.full_movement_speed, s.config.full_easing, nil, 0, false)
		engine.path_add_waypoint(&e.paths[fp], c)
		s.full_paths[id] = fp

		// full scene: starting color -> final fg
		sc := engine.new_scene(e, false, .None, {})
		g := engine.gradient_with_steps(
			[]engine.Color{s.config.starting_color, final.fg.?},
			10,
			false,
		)
		defer delete(g[:])
		engine.scene_add_gradient(&e.scenes[sc], []string{e.chars.input_symbol[id]}, 6, g[:], nil)
		s.full_scenes[id] = sc

		engine.activate_path(e, id, cp)
		engine.set_appearance(&e.chars, id, e.chars.input_symbol[id], s.config.starting_color, nil)
		e.chars.is_visible[id] = true
		engine.active_insert(e, id)
	}
}

middleout_next :: proc(s: ^Middleout_State, e: ^engine.Engine) -> bool {
	if !s.phase_full && len(e.active) == 0 {
		s.phase_full = true
		chars := engine.get_characters(
			engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas},
			engine.filter_input(),
			.Top_Bottom_Left_Right,
		)
		defer delete(chars[:])
		for id in chars {
			engine.activate_path(e, id, s.full_paths[id])
			engine.activate_scene(e, id, s.full_scenes[id])
			engine.active_insert(e, id)
		}
	}
	if len(e.active) == 0 do return false
	engine.update(e)
	engine.frame(e)
	return true
}
