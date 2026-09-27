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

// Particles with the same duration share the tick's scalar motion sample.
Scattered_Motion :: struct {
	progress, factor: f64,
}

Scattered_State :: struct {
	config:         Scattered_Config,
	characters:     [dynamic]engine.Particle_Id,
	active_indexes: [dynamic]int,
	final_index:    [dynamic]int, // spectrum index by slot
	fades:          engine.Gradient_Steps, // fades to each spectrum entry
	origins:        [dynamic]engine.Coord,
	motion_slots:   [dynamic]int,
	motion_steps:   [dynamic]int,
	motions:        [dynamic]Scattered_Motion,
	color_steps:    [dynamic]u8, // last published gradient sample; build installs zero
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
	s.final_index = make([dynamic]int, n)
	s.fades = engine.gradient_steps_make(e, s.config.final_gradient_stops[0], spectrum[:], 10)
	s.origins = make([dynamic]engine.Coord, n)
	s.active_indexes = make([dynamic]int, n)
	steps_by_particle := make([]int, n)
	defer delete(steps_by_particle)
	if s.color_handling != .Dynamic do s.color_steps = make([dynamic]u8, n)
	for id, i in s.characters {
		s.active_indexes[i] = i
		c := e.particles.initial_coord[id]
		s.final_index[i] = engine.gradient_sample_index(sampler, len(spectrum), c)

		start :=
			e.canvas.right < 2 || e.canvas.top < 2 ? engine.coord(1, 1) : engine.canvas_random_coord(e.canvas, false, false)
		e.particles.current_coord[id] = start
		s.origins[i] = start
		steps := max(
			engine.round_to_int(engine.line_length(start, c, true) / s.config.movement_speed),
			1,
		)
		steps_by_particle[i] = steps
		s.step_limit = max(s.step_limit, steps)
		e.particles.layer[id] = 1
		engine.set_symbol(e, id, e.particles.initial_symbol[engine.Particle_Id(id)])
		if s.color_handling == .Dynamic {
			engine.set_appearance(e, id, engine.Appearance{colors = engine.get_initial_appearance(e, id).colors})
		} else {
			engine.set_appearance(e, id, engine.gradient_step(s.fades, s.final_index[i], 0))
		}
		e.particles.flags[id] += {.Visible}
	}
	// Start tick and easing are common to the effect; duration is the only key.
	s.motion_steps, s.motion_slots = engine.group_values(steps_by_particle)
	s.motions = make([dynamic]Scattered_Motion, len(s.motion_steps))
	s.initial_hold = 25
}

scattered_next :: proc(s: ^Scattered_State, e: ^engine.Engine) -> bool #no_bounds_check {
	if s.tick == s.step_limit do return false
	if s.initial_hold > 0 {
		s.initial_hold -= 1
		return true
	}
	for steps, slot in s.motion_steps {
		if s.tick >= steps do continue
		motion := &s.motions[slot]
		motion.progress = f64(s.tick + 1) / f64(steps)
		motion.factor = ease.ease(s.config.movement_easing, motion.progress)
	}
	write := 0
	for i in s.active_indexes {
		id := s.characters[i]
		slot := s.motion_slots[i]
		motion := s.motions[slot]
		steps, progress := s.motion_steps[slot], motion.progress
		engine.set_particle(
			e,
			id,
			engine.coord_on_line(s.origins[i], e.particles.initial_coord[id], motion.factor),
		)
		// Dynamic input colors are installed during build and never change here.
		if s.color_handling != .Dynamic {
			step := min(engine.round_to_int(progress * 9), 10)
			if u8(step) != s.color_steps[i] {
				s.color_steps[i] = u8(step)
				engine.set_appearance(e, id, engine.gradient_step(s.fades, s.final_index[i], step))
			}
		}
		if s.tick + 1 >= steps {
			engine.set_particle(e, id, e.particles.initial_coord[id])
			if s.color_handling != .Dynamic {
				engine.set_appearance(e, id, engine.gradient_step(s.fades, s.final_index[i], s.fades.steps))
			}
			engine.set_particle(e, id, engine.Layer(0))
		} else {
			s.active_indexes[write] = i
			write += 1
		}
	}
	resize(&s.active_indexes, write)
	s.tick += 1
	return true
}
