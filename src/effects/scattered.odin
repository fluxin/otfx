package effects

import engine "../engine"

import "core:fmt"

// scattered — characters fly in from random coordinates with a slight
// overshoot easing, synced to movement distance.

Scattered_Config :: struct {
	movement_speed:           f64,
	movement_easing:          engine.Easing,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_frames:    int,
	final_gradient_direction: engine.Gradient_Direction,
}

scattered_config_default :: proc() -> Scattered_Config {
	cfg := Scattered_Config {
		movement_speed           = 0.5,
		movement_easing          = engine.ease_of(.Back_In_Out),
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
	config:        Scattered_Config,
	final_colors:  [dynamic]engine.Color_Pair,
	path_handles:  [dynamic]int,
	scene_handles: [dynamic]int,
	initial_hold:  int,
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

		start :=
			e.canvas.right < 2 || e.canvas.top < 2 ? engine.coord(1, 1) : engine.canvas_random_coord(e.canvas, false, false)
		e.chars.current_coord[id] = start
		p := engine.new_path(e, s.config.movement_speed, s.config.movement_easing, nil, 0, false)
		engine.path_add_waypoint(&e.paths[p], c)
		s.path_handles[id] = p

		// on activation raise the layer above fills; on completion drop back
		engine.register_event(e, id, .Path_Activated, .Path, p, {kind = .Set_Layer, layer = 1})
		engine.register_event(e, id, .Path_Complete, .Path, p, {kind = .Set_Layer, layer = 0})

		sc := engine.new_scene(e, false, .Distance, {})
		g := engine.gradient_with_steps([]engine.Color{spectrum[0], final.fg.?}, 10, false)
		defer delete(g[:])
		engine.scene_add_gradient(
			&e.scenes[sc],
			[]string{e.chars.input_symbol[id]},
			s.config.final_gradient_frames,
			g[:],
			nil,
		)
		s.scene_handles[id] = sc

		engine.activate_path(e, id, p)
		engine.activate_scene(e, id, sc)
		e.chars.is_visible[id] = true
		engine.active_insert(e, id)
	}
	s.initial_hold = 25
}

scattered_next :: proc(s: ^Scattered_State, e: ^engine.Engine) -> bool {
	if len(e.active) == 0 do return false
	if s.initial_hold > 0 {
		s.initial_hold -= 1
		engine.frame(e)
		return true
	}
	engine.update(e)
	engine.frame(e)
	return true
}
