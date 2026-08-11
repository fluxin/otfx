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
	config:     Bouncyballs_Config,
	row_groups: engine.Char_Groups,
	next_group: int,
	pending:    [dynamic]engine.Char_Id,
	ball_delay: int,
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
	characters := engine.get_characters(query, engine.filter_input(), .Top_Bottom_Left_Right)
	defer delete(characters[:])
	s.row_groups = engine.get_characters_grouped(query, engine.filter_input(), .Row_B2T)

	for id in characters {
		input_coord := e.chars.input_coord[id]
		ball_color := s.config.ball_colors[rand.int_max(len(s.config.ball_colors))]
		ball_symbol := s.config.ball_symbols[rand.int_max(len(s.config.ball_symbols))]
		ball_scene := engine.new_scene(e, false, .None, nil)
		engine.scene_add_frame(&e.scenes[ball_scene], ball_symbol, 1, ball_color, nil, false)

		final_color := engine.gradient_sample(sampler, spectrum[:], input_coord)
		fade := engine.gradient_with_steps([]engine.Color{ball_color, final_color}, 10, false)
		final_scene := engine.new_scene(e, false, .None, nil)
		engine.scene_add_gradient(
			&e.scenes[final_scene],
			[]string{e.chars.input_symbol[id]},
			6,
			fade[:],
			nil,
		)
		delete(fade[:])

		drop_row := int(f64(e.canvas.top) * rand.float64_range(1, 1.5))
		e.chars.current_coord[id] = engine.coord(input_coord.column, drop_row)
		path := engine.new_path(
			e,
			s.config.movement_speed,
			s.config.movement_easing,
			nil,
			0,
			false,
		)
		engine.path_add_waypoint(&e.paths[path], input_coord)
		engine.activate_path(e, id, path)
		engine.activate_scene(e, id, ball_scene)
		engine.register_event(
			e,
			id,
			.Path_Complete,
			.Path,
			path,
			{kind = .Activate_Scene, scene = final_scene},
		)
	}
}

bouncyballs_next :: proc(s: ^Bouncyballs_State, e: ^engine.Engine) -> bool {
	if s.next_group >= engine.group_count(s.row_groups) && len(s.pending) == 0 && len(e.active) == 0 do return false
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
				e.chars.is_visible[id] = true
				engine.active_insert(e, id)
			}
			s.ball_delay = s.config.ball_delay
		} else {
			s.ball_delay -= 1
		}
	}
	engine.update(e)
	engine.frame(e)
	return true
}
