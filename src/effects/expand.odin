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
	config:        Expand_Config,
	final_colors:  [dynamic]engine.Color_Pair,
	path_handles:  [dynamic]int,
	scene_handles: [dynamic]int,
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
		final := engine.Color_Pair {
			fg = engine.gradient_sample(sampler, spectrum[:], c),
			bg = nil,
		}
		s.final_colors[id] = final

		e.chars.current_coord[id] = e.canvas.center
		p := engine.new_path(e, s.config.movement_speed, s.config.expand_easing, nil, 0, false)
		engine.path_add_waypoint(&e.paths[p], c)
		s.path_handles[id] = p
		engine.register_event(e, id, .Path_Activated, .Path, p, {kind = .Set_Layer, layer = 1})
		engine.register_event(e, id, .Path_Complete, .Path, p, {kind = .Set_Layer, layer = 0})

		sc := engine.new_scene(e, false, .Distance, {})
		g := engine.gradient_with_steps([]engine.Color{spectrum[0], final.fg.?}, 10, false)
		defer delete(g[:])
		engine.scene_add_gradient(&e.scenes[sc], []string{e.chars.input_symbol[id]}, 5, g[:], nil)
		s.scene_handles[id] = sc

		engine.activate_path(e, id, p)
		engine.activate_scene(e, id, sc)
		e.chars.is_visible[id] = true
		engine.active_insert(e, id)
	}
}

expand_next :: proc(s: ^Expand_State, e: ^engine.Engine) -> bool {
	if len(e.active) == 0 do return false
	engine.update(e)
	engine.frame(e)
	return true
}
