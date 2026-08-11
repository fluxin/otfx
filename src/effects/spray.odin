package effects

import engine "../engine"

import "core:fmt"
import "core:math"
import rand "core:math/rand"

Spray_Position :: enum {
	N,
	Ne,
	E,
	Se,
	S,
	Sw,
	W,
	Nw,
	Center,
}

Spray_Config :: struct {
	spray_position:           Spray_Position,
	spray_volume:             f64,
	movement_speed_range:     Float_Range_Value,
	movement_easing:          engine.Easing,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

spray_config_default :: proc() -> Spray_Config {
	cfg := Spray_Config {
		spray_position           = .E,
		spray_volume             = 0.005,
		movement_speed_range     = {0.6, 1.4},
		movement_easing          = engine.ease_of(.Exponential_Out),
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

spray_parse :: proc(cfg: ^Spray_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--spray-position":
			v, ok := opt_value(args, &i, value, has_value)
			if !ok do return false
			switch v {
			case "n":
				cfg.spray_position = .N
			case "ne":
				cfg.spray_position = .Ne
			case "e":
				cfg.spray_position = .E
			case "se":
				cfg.spray_position = .Se
			case "s":
				cfg.spray_position = .S
			case "sw":
				cfg.spray_position = .Sw
			case "w":
				cfg.spray_position = .W
			case "nw":
				cfg.spray_position = .Nw
			case "center":
				cfg.spray_position = .Center
			case:
				return false
			}
		case "--spray-volume":
			if !parse_float_flag(&cfg.spray_volume, args, &i, value, has_value) ||
			   cfg.spray_volume <= 0 ||
			   cfg.spray_volume > 1 {
				return false
			}
		case "--movement-speed-range":
			if !parse_float_range_flag(&cfg.movement_speed_range, args, &i, value, has_value) do return false
		case "--movement-easing":
			if !parse_ease_flag(&cfg.movement_easing, args, &i, value, has_value) do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown spray option: ", name)
			return false
		}
	}
	return true
}

Spray_State :: struct {
	config:  Spray_Config,
	pending: [dynamic]engine.Char_Id,
	volume:  int,
}

spray_origin :: proc(position: Spray_Position, canvas: engine.Canvas) -> engine.Coord {
	switch position {
	case .Center:
		return canvas.center
	case .N:
		return engine.coord(math.floor_div(canvas.right, 2), canvas.top)
	case .Nw:
		return engine.coord(canvas.left, canvas.top)
	case .W:
		return engine.coord(canvas.left, math.floor_div(canvas.top, 2))
	case .Sw:
		return engine.coord(canvas.left, canvas.bottom)
	case .S:
		return engine.coord(math.floor_div(canvas.right, 2), canvas.bottom)
	case .Se:
		return engine.coord(canvas.right - 1, canvas.bottom)
	case .E:
		return engine.coord(canvas.right - 1, math.floor_div(canvas.top, 2))
	case .Ne:
		return engine.coord(canvas.right - 1, canvas.top)
	}
	return canvas.center
}

spray_build :: proc(s: ^Spray_State, e: ^engine.Engine) {
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

	origin := spray_origin(s.config.spray_position, e.canvas)
	for id in characters {
		input_coord := e.chars.input_coord[id]
		final_color := engine.gradient_sample(sampler, spectrum[:], input_coord)
		speed := rand.float64_range(
			s.config.movement_speed_range.lo,
			s.config.movement_speed_range.hi,
		)
		e.chars.current_coord[id] = origin
		path := engine.new_path(e, speed, s.config.movement_easing, nil, 0, false)
		engine.path_add_waypoint(&e.paths[path], input_coord)
		engine.register_event(e, id, .Path_Activated, .Path, path, {kind = .Set_Layer, layer = 1})
		engine.register_event(e, id, .Path_Complete, .Path, path, {kind = .Set_Layer, layer = 0})

		start_color := spectrum[rand.int_max(len(spectrum))]
		gradient := engine.gradient_with_steps([]engine.Color{start_color, final_color}, 7, false)
		scene := engine.new_scene(e, false, .None, nil)
		engine.scene_add_gradient(
			&e.scenes[scene],
			[]string{e.chars.input_symbol[id]},
			20,
			gradient[:],
			nil,
		)
		delete(gradient[:])
		engine.activate_scene(e, id, scene)
		engine.activate_path(e, id, path)
		append(&s.pending, id)
	}
	rand.shuffle(s.pending[:])
	s.volume = max(int(f64(len(s.pending)) * s.config.spray_volume), 1)
}

spray_next :: proc(s: ^Spray_State, e: ^engine.Engine) -> bool {
	if len(s.pending) == 0 && len(e.active) == 0 do return false
	if len(s.pending) > 0 {
		for _ in 0 ..< rand.int_range(1, s.volume + 1) {
			if len(s.pending) == 0 do break
			id := pop(&s.pending)
			e.chars.is_visible[id] = true
			engine.active_insert(e, id)
		}
	}
	engine.update(e)
	engine.frame(e)
	return true
}
