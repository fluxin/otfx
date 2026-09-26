package effects

import "../engine"

import "core:fmt"
import "core:math/ease"

// scattered — characters fly in from random coordinates with a slight
// overshoot easing, synced to movement distance.

Scattered_Config :: struct {
	movement_speed:           f64,
	movement_easing:          ease.Ease,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_frames:    int,
	final_gradient_direction: engine.Gradient_Direction,
}

scattered_config_default :: proc() -> Scattered_Config {
	cfg := Scattered_Config {
		movement_speed           = 0.5,
		movement_easing          = .Back_In_Out,
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
			if !parse_float_flag(&cfg.movement_speed, args, &i, value, has_value) || cfg.movement_speed <= 0 do return false
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
	config:         Scattered_Config,
	characters:     [dynamic]engine.Particle_Id,
	final_colors:   [dynamic]engine.Color,
	origins:        [dynamic]engine.Coord,
	max_steps:      [dynamic]int,
	step_limit:     int,
	tick:           int,
	initial_hold:   int,
	color_handling: engine.Existing_Color_Handling,
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
	s.final_colors = make([dynamic]engine.Color, n)
	s.origins = make([dynamic]engine.Coord, n)
	s.max_steps = make([dynamic]int, n)
	for id, i in s.characters {
		c := e.particles.initial_coord[id]
		s.final_colors[i] = engine.gradient_sample(sampler, spectrum[:], c)

		start :=
			e.canvas.right < 2 || e.canvas.top < 2 ? engine.coord(1, 1) : engine.canvas_random_coord(e.canvas, false, false)
		e.particles.current_coord[id] = start
		s.origins[i] = start
		s.max_steps[i] = max(
			engine.round_to_int(engine.line_length(start, c, true) / s.config.movement_speed),
			1,
		)
		s.step_limit = max(s.step_limit, s.max_steps[i])
		e.particles.layer[id] = 1
		engine.set_symbol(e, id, e.particles.initial_symbol[engine.Particle_Id(id)])
		engine.set_appearance(
			e,
			id,
			engine.Appearance {
				colors = {
					fg = s.color_handling == .Dynamic ? engine.get_initial_appearance(e, engine.Particle_Id(id)).colors.fg : spectrum[0],
					bg = s.color_handling == .Dynamic ? engine.get_initial_appearance(e, engine.Particle_Id(id)).colors.bg : nil,
				},
			},
		)
		e.particles.flags[id] += {.Visible}
	}
	s.initial_hold = 25
}

scattered_next :: proc(s: ^Scattered_State, e: ^engine.Engine) -> bool {
	if s.tick == s.step_limit do return false
	if s.initial_hold > 0 {
		s.initial_hold -= 1
		return true
	}
	for id, i in s.characters {
		steps := s.max_steps[i]
		// The arrival tick already published the final coordinate, color, and layer.
		if s.tick >= steps do continue
		progress := f64(min(s.tick + 1, steps)) / f64(steps)
		engine.set_particle(
			e,
			id,
			engine.coord_on_line(
				s.origins[i],
				e.particles.initial_coord[id],
				ease.ease(s.config.movement_easing, progress),
			),
		)
		if s.color_handling == .Dynamic {
			appearance := engine.get_appearance(e, id)
			engine.dynamic_apply_input_colors(
				&appearance,
				engine.get_initial_appearance(e, engine.Particle_Id(id)),
			)
			engine.set_appearance(e, id, appearance)
		} else {
			engine.set_foreground(
				e,
				id,
				engine.gradient_between_step(
					s.config.final_gradient_stops[0],
					s.final_colors[i],
					10,
					min(engine.round_to_int(progress * 9), 10),
				),
			)
		}
		if s.tick + 1 >= steps {
			engine.set_particle(e, id, e.particles.initial_coord[id])
			if s.color_handling == .Dynamic {
				appearance := engine.get_appearance(e, id)
				engine.dynamic_apply_input_colors(
					&appearance,
					engine.get_initial_appearance(e, engine.Particle_Id(id)),
				)
				engine.set_appearance(e, id, appearance)
			} else {
				engine.set_foreground(e, id, s.final_colors[i])
			}
			engine.set_particle(e, id, engine.Layer(0))
		}
	}
	s.tick += 1
	return true
}
