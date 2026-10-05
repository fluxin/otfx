package effects

import "../engine"

import "core:fmt"
import "core:math"
import "core:math/ease"

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
	characters:     [dynamic]engine.Particle_Id,
	index_by_id:    [dynamic]int,
	pending:        [dynamic]engine.Particle_Id,
	active_indexes: [dynamic]int,
	targets:        [dynamic]engine.Coord,
	fades:          engine.Appearance_Ramp,
	fade_index:     [dynamic]int,
	max_steps:      [dynamic]int,
	start_ticks:    [dynamic]int,
	origin:         engine.Coord,
	volume:         int,
	tick:           int,
	last_tick:      int,
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
		context.temp_allocator,
	)
	defer delete(spectrum)
	sampler := engine.gradient_sampler(
		e.canvas.text_bottom,
		e.canvas.text_top,
		e.canvas.text_left,
		e.canvas.text_right,
		s.config.final_gradient_direction,
	)
	s.characters = engine.get_particles(
		engine.Particle_Query {
			e.particle_sets,
			e.particles.initial_coord[:len(e.particles)],
			e.canvas,
		},
		engine.PARTICLE_FILTER_INPUT,
		.Top_Bottom_Left_Right,
	)
	n := len(s.characters)
	reserve(&s.active_indexes, n)
	reserve(&s.pending, n)
	s.color_handling = e.cfg.existing_color_handling
	s.index_by_id = make([dynamic]int, len(e.particles))
	s.targets = make([dynamic]engine.Coord, n)
	s.max_steps = make([dynamic]int, n)
	s.start_ticks = make([dynamic]int, n)
	s.origin = spray_origin(s.config.spray_position, e.canvas)
	if n == 0 do return

	fade_tweens := make([]engine.Tween(engine.Appearance), n, context.temp_allocator)
	defer delete(fade_tweens, context.temp_allocator)

	for id, i in s.characters {
		s.index_by_id[id] = i
		initial_coord := e.particles.initial_coord[id]
		s.targets[i] = initial_coord
		final_color := engine.gradient_sample(sampler, spectrum[:], initial_coord)
		start_color := spectrum[engine.random_below(len(spectrum))]
		if s.color_handling == .Dynamic {
			init_style := engine.get_initial_appearance(e, id)
			fade_tweens[i] = {
				from = {colors = {start_color, start_color}},
				to   = {colors = init_style.colors},
			}
		} else {
			fade_tweens[i] = {
				from = {colors = {fg = start_color}},
				to   = {colors = {fg = final_color}},
			}
		}
		speed := engine.random_float_range(
			s.config.movement_speed_range.lo,
			s.config.movement_speed_range.hi,
		)
		e.particles.current_coord[id] = s.origin
		s.max_steps[i] = max(
			engine.round_to_int(engine.line_length(s.origin, initial_coord, true) / speed),
			1,
		)
		s.start_ticks[i] = -1
		append(&s.pending, id)
	}
	unique_tweens: [dynamic]engine.Tween(engine.Appearance)
	unique_tweens, s.fade_index = engine.group_values(fade_tweens)
	defer delete(unique_tweens)
	s.fades = engine.ramp_make(e, unique_tweens[:], 7)

	engine.random_shuffle(s.pending[:])
	s.volume = max(int(f64(len(s.pending)) * s.config.spray_volume), 1)
}

spray_next :: proc(s: ^Spray_State, e: ^engine.Engine) -> bool #no_bounds_check {
	if len(s.pending) == 0 && s.tick >= s.last_tick do return false
	if len(s.pending) > 0 {
		for _ in 0 ..< engine.random_range(1, s.volume + 1) {
			if len(s.pending) == 0 do break
			id := pop(&s.pending)
			i := s.index_by_id[id]
			s.start_ticks[i] = s.tick
			s.last_tick = max(s.last_tick, s.tick + max(s.max_steps[i], 160))
			append(&s.active_indexes, i)
			engine.set_visible(e, id, true)
		}
	}
	write := 0
	for i in s.active_indexes {
		id := s.characters[i]
		start := s.start_ticks[i]
		age := s.tick - start
		max_step := s.max_steps[i]
		// Keep the arrival boundary for the layer reset, even after motion stops.
		if age < max(max_step, 140) {
			s.active_indexes[write] = i
			write += 1
		}
		if age < max_step {
			progress := f64(age + 1) / f64(max_step)
			pos := engine.tween(
				s.origin,
				s.targets[i],
				ease.ease(s.config.movement_easing, progress),
			)
			engine.set_placement(e, id, pos, true, 1)
		} else if age == max_step {
			engine.set_placement(e, id, s.targets[i], true, 0)
		}
		if age > 140 || age % 20 != 0 do continue
		engine.set_appearance(e, id, engine.ramp_code(s.fades, s.fade_index[i], min(age / 20, 7)))
	}
	resize(&s.active_indexes, write)
	s.tick += 1
	return true
}
