package effects

import "../engine"

import "core:fmt"
import "core:math/ease"

// expand — all characters start at the canvas center and fly home.

Expand_Config :: struct {
	expand_easing:            ease.Ease,
	movement_speed:           f64,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

expand_config_default :: proc() -> Expand_Config {
	cfg := Expand_Config {
		expand_easing            = .Quartic_In_Out,
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
			if !parse_float_flag(&cfg.movement_speed, args, &i, value, has_value) || cfg.movement_speed <= 0 do return false
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
	config:         Expand_Config,
	characters:     [dynamic]engine.Particle_Id,
	colors:         [dynamic][11]engine.Color_Pair,
	active_indexes: [dynamic]int,
	motion_slots:   [dynamic]int,
	motion_factors: [dynamic]f64,
	color_steps:    [dynamic]int,
	max_steps:      [dynamic]int,
	step_limit:     int,
	tick:           int,
	color_handling: engine.Existing_Color_Handling,
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
	s.color_handling = e.cfg.existing_color_handling
	s.colors = make([dynamic][11]engine.Color_Pair, n)
	s.active_indexes = make([dynamic]int, n)
	steps := make([]int, n, context.temp_allocator)
	s.color_steps = make([dynamic]int, n)
	for &step in s.color_steps do step = -1

	for id, i in s.characters {
		c := e.particles.initial_coord[id]
		final_color := engine.gradient_sample(sampler, spectrum[:], c)
		input := engine.get_initial_appearance(e, id)
		for step in 0 ..< 11 {
			appearance := engine.get_appearance(e, id)
			if s.color_handling == .Dynamic {
				engine.dynamic_gradient_to_input(
					&appearance,
					s.config.final_gradient_stops[0],
					input,
					10,
					step,
				)
			} else {
				appearance.colors.fg = engine.gradient_between_step(
					s.config.final_gradient_stops[0],
					final_color,
					10,
					step,
				)
			}
			s.colors[i][step] = appearance.colors
		}
		s.active_indexes[i] = i
		e.particles.current_coord[id] = e.canvas.center
		steps[i] = max(
			engine.round_to_int(
				engine.line_length(e.canvas.center, c, true) / s.config.movement_speed,
			),
			1,
		)
		s.step_limit = max(s.step_limit, steps[i])
		e.particles.flags[id] += {.Visible}
		e.particles.layer[id] = 1
	}
	s.max_steps, s.motion_slots = engine.group_values(steps)
	s.motion_factors = make([dynamic]f64, len(s.max_steps))
}

expand_next :: proc(s: ^Expand_State, e: ^engine.Engine) -> bool #no_bounds_check {
	if s.tick == s.step_limit do return false
	for steps, slot in s.max_steps {
		if s.tick < steps do s.motion_factors[slot] = ease.ease(s.config.expand_easing, f64(s.tick + 1) / f64(steps))
	}
	write := 0
	for i in s.active_indexes {
		id := s.characters[i]
		slot := s.motion_slots[i]
		maximum := s.max_steps[slot]
		factor := s.motion_factors[slot]
		position := engine.coord_on_line(e.canvas.center, e.particles.initial_coord[id], factor)
		step := min(engine.round_to_int(factor * 10), 10)
		if s.tick + 1 == maximum {
			position = e.particles.initial_coord[id]
			step = 10
			engine.set_particle(e, id, engine.Layer(0))
		} else {
			s.active_indexes[write] = i
			write += 1
		}
		engine.set_particle(e, id, position)
		if step != s.color_steps[i] {
			s.color_steps[i] = step
			appearance := engine.get_appearance(e, id)
			appearance.colors = s.colors[i][step]
			engine.set_appearance(e, id, appearance)
		}
	}
	resize(&s.active_indexes, write)
	s.tick += 1
	return true
}
