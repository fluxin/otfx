package effects

import "../engine"

import "core:fmt"
import "core:math/ease"

// wipe — reveal characters along a grouped direction, eased.

Wipe_Config :: struct {
	wipe_direction:           engine.Particle_Group,
	wipe_delay:               int,
	wipe_ease:                ease.Ease,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_frames:    int,
	final_gradient_direction: engine.Gradient_Direction,
}

wipe_config_default :: proc() -> Wipe_Config {
	cfg := Wipe_Config {
		wipe_direction           = .Diagonal_TL2BR,
		wipe_ease                = .Circular_In_Out,
		final_gradient_frames    = 3,
		final_gradient_direction = .Vertical,
	}
	append(
		&cfg.final_gradient_stops,
		..[]engine.Color {
			engine.Color{0x83, 0x3a, 0xb4},
			engine.Color{0xfd, 0x1d, 0x1d},
			engine.Color{0xfc, 0xb0, 0x45},
		},
	)
	append(&cfg.final_gradient_steps, 12)
	return cfg
}

wipe_parse :: proc(cfg: ^Wipe_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--wipe-direction":
			if !parse_group_flag(&cfg.wipe_direction, args, &i, value, has_value) do return false
		case "--wipe-delay":
			if !parse_int_flag(&cfg.wipe_delay, args, &i, value, has_value, minimum = 0) do return false
		case "--wipe-ease":
			if !parse_ease_flag(&cfg.wipe_ease, args, &i, value, has_value) do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-frames":
			if !parse_int_flag(&cfg.final_gradient_frames, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown wipe option: ", name)
			return false
		}
	}
	return true
}

Wipe_State :: struct {
	config:         Wipe_Config,
	frames:         engine.Frame_Timeline,
	frame_spans:    [dynamic]engine.Span,
	start_ticks:    [dynamic]int,
	active:         [dynamic]engine.Particle_Id,
	active_by_id:   [dynamic]u8,
	reveal:         engine.Group_Reveal,
	wipe_delay:     int,
	color_handling: engine.Existing_Color_Handling,
	tick:           int,
}

wipe_build :: proc(s: ^Wipe_State, e: ^engine.Engine) {
	groups := engine.get_particles_grouped(
		engine.Particle_Query {
			e.particle_sets,
			e.particles.initial_coord[:len(e.particles)],
			e.canvas,
		},
		engine.PARTICLE_FILTER_INPUT,
		s.config.wipe_direction,
	)
	s.reveal = engine.Group_Reveal {
		groups   = groups,
		ease     = s.config.wipe_ease,
		duration = 100,
	}

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

	chars := engine.get_particles(
		engine.Particle_Query {
			e.particle_sets,
			e.particles.initial_coord[:len(e.particles)],
			e.canvas,
		},
		engine.PARTICLE_FILTER_INPUT,
		.Top_Bottom_Left_Right,
	)
	defer delete(chars[:])
	reserve(&s.active, len(chars))
	s.color_handling = e.cfg.existing_color_handling
	s.frame_spans = make([dynamic]engine.Span, len(e.particles))
	s.start_ticks = make([dynamic]int, len(e.particles))
	for i in 0 ..< len(s.start_ticks) do s.start_ticks[i] = -1
	s.active_by_id = make([dynamic]u8, len(e.particles))
	gradient_steps := s.config.final_gradient_steps[0]
	reserve(&s.frames, len(chars) * (gradient_steps + 1))

	for id in chars {
		switch s.color_handling {
		case .Dynamic:
			s.frame_spans[id] = engine.create_timeline(
				&s.frames,
				e.particles.initial_symbol[id],
				engine.Appearance{colors = engine.get_initial_appearance(e, id).colors},
				s.config.final_gradient_frames,
				gradient_steps + 1,
			)
		case .Ignore, .Always:
			final := engine.gradient_sample(sampler, spectrum[:], e.particles.initial_coord[id])
			s.frame_spans[id] = engine.create_timeline(
				&s.frames,
				e.particles.initial_symbol[engine.Particle_Id(id)],
				s.config.final_gradient_frames,
				spectrum[0],
				final,
				gradient_steps,
			)
		}
	}
	s.wipe_delay = s.config.wipe_delay
}

wipe_next :: proc(s: ^Wipe_State, e: ^engine.Engine) -> bool {
	if len(s.active) == 0 && engine.group_reveal_complete(s.reveal) {
		return false
	}
	if s.wipe_delay == 0 {
		change := engine.group_reveal_step(&s.reveal)
		for gi in change.added.start ..< change.added.start + change.added.len {
			for id in engine.group_members(s.reveal.groups, gi) {
				engine.set_particle(e, id, engine.Visible(true))
				s.start_ticks[id] = s.tick
				if s.active_by_id[id] == 0 {
					s.active_by_id[id] = 1
					append(&s.active, id)
				}
			}
		}
		for gi in change.removed.start ..< change.removed.start + change.removed.len {
			for id in engine.group_members(s.reveal.groups, gi) {
				s.active_by_id[id] = 0
				s.start_ticks[id] = -1
				engine.set_particle(e, id, engine.Visible(false))
			}
		}
		s.wipe_delay = s.config.wipe_delay
	} else {
		s.wipe_delay -= 1
	}
	write := 0
	for id in s.active {
		if s.active_by_id[id] == 0 do continue
		span := s.frame_spans[id]
		age := s.tick - s.start_ticks[id]
		frame := age / s.config.final_gradient_frames
		engine.set_symbol(e, id, s.frames[span.start + frame].symbol)
		engine.set_appearance(e, id, s.frames[span.start + frame].appearance)
		if age + 1 == span.len * s.config.final_gradient_frames {
			s.active_by_id[id] = 0
		} else {
			s.active[write] = id
			write += 1
		}
	}
	resize(&s.active, write)
	s.tick += 1
	return true
}
