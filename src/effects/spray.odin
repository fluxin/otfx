package effects

import "../engine"

import "core:fmt"
import "core:math"
import "core:math/ease"
import "core:math/rand"

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
	movement_easing:          ease.Ease,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

spray_config_default :: proc() -> Spray_Config {
	cfg := Spray_Config {
		spray_position           = .E,
		spray_volume             = 0.005,
		movement_speed_range     = {0.6, 1.4},
		movement_easing          = .Exponential_Out,
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
	config:         Spray_Config,
	characters:     [dynamic]engine.Char_Id,
	index_by_id:    [dynamic]int,
	pending:        [dynamic]engine.Char_Id,
	final_colors:   [dynamic]engine.Color,
	start_colors:   [dynamic]engine.Color,
	max_steps:      [dynamic]int,
	start_ticks:    [dynamic]int,
	origin:         engine.Coord,
	volume:         int,
	tick:           int,
	color_handling: engine.Existing_Color_Handling,
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
	s.characters = engine.get_characters(
		engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas},
		engine.CHAR_FILTER_INPUT,
		.Top_Bottom_Left_Right,
	)
	n := len(s.characters)
	s.color_handling = e.cfg.existing_color_handling
	s.index_by_id = make([dynamic]int, len(e.chars))
	s.final_colors = make([dynamic]engine.Color, n)
	s.start_colors = make([dynamic]engine.Color, n)
	s.max_steps = make([dynamic]int, n)
	s.start_ticks = make([dynamic]int, n)
	s.origin = spray_origin(s.config.spray_position, e.canvas)
	for id, i in s.characters {
		s.index_by_id[id] = i
		input_coord := e.chars.input_coord[id]
		s.final_colors[i] = engine.gradient_sample(sampler, spectrum[:], input_coord)
		s.start_colors[i] = spectrum[rand.int_max(len(spectrum))]
		speed := rand.float64_range(
			s.config.movement_speed_range.lo,
			s.config.movement_speed_range.hi,
		)
		e.chars.current_coord[id] = s.origin
		s.max_steps[i] = max(
			engine.round_half_even(engine.line_length(s.origin, input_coord, true) / speed),
			1,
		)
		s.start_ticks[i] = -1
		append(&s.pending, id)
	}
	rand.shuffle(s.pending[:])
	s.volume = max(int(f64(len(s.pending)) * s.config.spray_volume), 1)
}

spray_next :: proc(s: ^Spray_State, e: ^engine.Engine) -> ([]engine.Char_Id, bool) {
	active := len(s.pending) != 0
	for _, i in s.characters {
		start := s.start_ticks[i]
		if start >= 0 && s.tick - start < max(s.max_steps[i], 160) {
			active = true
			break
		}
	}
	if !active do return nil, false
	if len(s.pending) > 0 {
		for _ in 0 ..< rand.int_range(1, s.volume + 1) {
			if len(s.pending) == 0 do break
			id := pop(&s.pending)
			s.start_ticks[s.index_by_id[id]] = s.tick
			e.chars.is_visible[id] = true
		}
	}
	for id, i in s.characters {
		start := s.start_ticks[i]
		if start < 0 do continue
		age := s.tick - start
		if age < s.max_steps[i] {
			progress := f64(age + 1) / f64(s.max_steps[i])
			e.chars.current_coord[id] = engine.coord_on_line(
				s.origin,
				e.chars.input_coord[id],
				ease.ease(s.config.movement_easing, progress),
			)
			e.chars.layer[id] = 1
		} else {
			e.chars.current_coord[id] = e.chars.input_coord[id]
			e.chars.layer[id] = 0
		}
		if s.color_handling == .Dynamic {
			step := min(age / 20, 7)
			engine.dynamic_gradient_to_input(
				&e.chars.visual[id],
				s.start_colors[i],
				e.chars.input_style[id],
				7,
				step,
			)
		} else if age < 160 {
			e.chars.visual[id].fg = engine.gradient_between_step(
				s.start_colors[i],
				s.final_colors[i],
				7,
				min(age / 20, 7),
			)
		} else {
			e.chars.visual[id].fg = s.final_colors[i]
		}
	}
	s.tick += 1
	return s.characters[:], true
}
