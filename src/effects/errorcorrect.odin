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
		error_color              = engine.Color{0xe7, 0x4c, 0x3c},
		correct_color            = engine.Color{0x45, 0xbf, 0x55},
		movement_speed           = 0.9,
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
			fmt.eprintln("Error: unknown errorcorrect option: ", name)
			return false
		}
	}
	return true
}

Errorcorrect_Pair :: struct {
	first, second: engine.Char_Id,
}

Errorcorrect_State :: struct {
	config:       Errorcorrect_Config,
	swapped:      [dynamic]Errorcorrect_Pair,
	swapped_head: int,
	error_scenes: [dynamic]int,
	swap_delay:   int,
}

errorcorrect_configure :: proc(
	s: ^Errorcorrect_State,
	e: ^engine.Engine,
	id: engine.Char_Id,
	path: int,
	final_color: engine.Color,
	correcting_gradient: []engine.Color,
) {
	input_symbol := e.chars.input_symbol[id]
	first_wipe := engine.new_scene(e, false, .None, nil)
	for symbol in ([]string{"▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"}) {
		engine.scene_add_frame(&e.scenes[first_wipe], symbol, 3, s.config.error_color, nil, false)
	}
	last_wipe := engine.new_scene(e, false, .None, nil)
	for symbol in ([]string{"▇", "▆", "▅", "▄", "▃", "▂", "▁"}) {
		engine.scene_add_frame(&e.scenes[last_wipe], symbol, 3, s.config.correct_color, nil, false)
	}

	error_scene := engine.new_scene(e, false, .None, nil)
	white := engine.Color{0xff, 0xff, 0xff}
	for _ in 0 ..< 10 {
		engine.scene_add_frame(&e.scenes[error_scene], "▓", 3, s.config.error_color, nil, false)
		engine.scene_add_frame(&e.scenes[error_scene], input_symbol, 3, white, nil, false)
	}
	s.error_scenes[id] = error_scene

	correcting_scene := engine.new_scene(e, false, .Distance, nil)
	engine.scene_add_gradient(
		&e.scenes[correcting_scene],
		[]string{"█"},
		3,
		correcting_gradient,
		nil,
	)
	final_scene := engine.new_scene(e, false, .None, nil)
	final_gradient := engine.gradient_with_steps(
		[]engine.Color{s.config.correct_color, final_color},
		10,
		false,
	)
	engine.scene_add_gradient(
		&e.scenes[final_scene],
		[]string{input_symbol},
		3,
		final_gradient[:],
		nil,
	)
	delete(final_gradient[:])

	engine.register_event(
		e,
		id,
		.Scene_Complete,
		.Scene,
		error_scene,
		{kind = .Activate_Scene, scene = first_wipe},
	)
	engine.register_event(
		e,
		id,
		.Scene_Complete,
		.Scene,
		first_wipe,
		{kind = .Activate_Scene, scene = correcting_scene},
	)
	engine.register_event(
		e,
		id,
		.Scene_Complete,
		.Scene,
		first_wipe,
		{kind = .Activate_Path, path = path},
	)
	engine.register_event(e, id, .Path_Activated, .Path, path, {kind = .Set_Layer, layer = 1})
	engine.register_event(e, id, .Path_Complete, .Path, path, {kind = .Set_Layer, layer = 0})
	engine.register_event(
		e,
		id,
		.Path_Complete,
		.Path,
		path,
		{kind = .Activate_Scene, scene = last_wipe},
	)
	engine.register_event(
		e,
		id,
		.Scene_Complete,
		.Scene,
		last_wipe,
		{kind = .Activate_Scene, scene = final_scene},
	)
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
		engine.filter_input(),
		.Top_Bottom_Left_Right,
	)
	defer delete(characters[:])
	final_colors := make([]engine.Color, len(e.chars), context.temp_allocator)
	s.error_scenes = make([dynamic]int, len(e.chars))
	for id in characters {
		final_colors[id] = engine.gradient_sample(sampler, spectrum[:], e.chars.input_coord[id])
		engine.set_appearance(&e.chars, id, e.chars.input_symbol[id], final_colors[id], nil)
		e.chars.is_visible[id] = true
		s.error_scenes[id] = -1
	}

	available := make([dynamic]engine.Char_Id, 0, len(characters), context.temp_allocator)
	append(&available, ..characters[:])
	correcting := engine.gradient_with_steps(
		[]engine.Color{s.config.error_color, s.config.correct_color},
		10,
		false,
	)
	defer delete(correcting[:])
	pair_count := int(s.config.error_pairs * f64(len(characters)))
	for _ in 0 ..< pair_count {
		if len(available) < 2 do break
		first_index := rand.int_max(len(available))
		first := available[first_index]
		ordered_remove(&available, first_index)
		second_index := rand.int_max(len(available))
		second := available[second_index]
		ordered_remove(&available, second_index)
		first_home := e.chars.input_coord[first]
		second_home := e.chars.input_coord[second]
		e.chars.current_coord[first] = second_home
		e.chars.current_coord[second] = first_home
		first_path := engine.new_path(e, s.config.movement_speed, nil, nil, 0, false)
		second_path := engine.new_path(e, s.config.movement_speed, nil, nil, 0, false)
		engine.path_add_waypoint(&e.paths[first_path], first_home)
		engine.path_add_waypoint(&e.paths[second_path], second_home)
		errorcorrect_configure(s, e, first, first_path, final_colors[first], correcting[:])
		errorcorrect_configure(s, e, second, second_path, final_colors[second], correcting[:])
		append(&s.swapped, Errorcorrect_Pair{first, second})
	}
}

errorcorrect_next :: proc(s: ^Errorcorrect_State, e: ^engine.Engine) -> bool {
	if s.swapped_head < len(s.swapped) && s.swap_delay == 0 {
		pair := s.swapped[s.swapped_head]
		s.swapped_head += 1
		for id in ([]engine.Char_Id{pair.first, pair.second}) {
			engine.activate_scene(e, id, s.error_scenes[id])
			engine.active_insert(e, id)
		}
		s.swap_delay = s.config.swap_delay
	} else if s.swap_delay != 0 {
		s.swap_delay -= 1
	}
	if len(e.active) == 0 do return false
	engine.update(e)
	engine.frame(e)
	return true
}
