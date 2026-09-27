package effects

import "../engine"
import "core:math/ease"
import "core:math/rand"

import "core:fmt"

// sweep — a gray shimmer sweeps across the whole canvas, then a colored sweep
// lands the final gradient.

Sweep_Config :: struct {
	sweep_symbols:            [dynamic]rune,
	first_sweep_direction:    engine.Particle_Group,
	second_sweep_direction:   engine.Particle_Group,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

sweep_config_default :: proc() -> Sweep_Config {
	cfg := Sweep_Config {
		first_sweep_direction    = .Column_R2L,
		second_sweep_direction   = .Column_L2R,
		final_gradient_direction = .Vertical,
	}
	append(&cfg.sweep_symbols, ..[]rune{'█', '▓', '▒', '░'})
	append(
		&cfg.final_gradient_stops,
		..[]engine.Color {
			engine.Color{0x8A, 0x00, 0x8A},
			engine.Color{0x00, 0xD1, 0xFF},
			engine.Color{0xff, 0xff, 0xff},
		},
	)
	append(&cfg.final_gradient_steps, 8)
	return cfg
}

sweep_parse :: proc(cfg: ^Sweep_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--sweep-symbols":
			if !parse_symbols_flag(&cfg.sweep_symbols, args, &i, value, has_value) do return false
		case "--first-sweep-direction":
			if !parse_group_flag(&cfg.first_sweep_direction, args, &i, value, has_value) do return false
		case "--second-sweep-direction":
			if !parse_group_flag(&cfg.second_sweep_direction, args, &i, value, has_value) do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown sweep option: ", name)
			return false
		}
	}
	return true
}

gray_shades: [5]engine.Color = {
	{0xA0, 0xA0, 0xA0},
	{0x80, 0x80, 0x80},
	{0x40, 0x40, 0x40},
	{0x20, 0x20, 0x20},
	{0x10, 0x10, 0x10},
}

Sweep_State :: struct {
	config:                       Sweep_Config,
	frames:                       engine.Frame_Timeline,
	first_frame_spans:            [dynamic]engine.Span,
	second_frame_spans:           [dynamic]engine.Span,
	start_ticks:                  [dynamic]int,
	active:                       [dynamic]engine.Particle_Id,
	active_phase:                 [dynamic]i8, // -1 inactive, 0 first lane, 1 second lane
	reveal:                       engine.Group_Reveal,
	second_groups:                engine.Particle_Groups,
	dynamic_second_sweep_palette: [dynamic]engine.Color,
	first_phase:                  bool,
	complete:                     bool,
	color_handling:               engine.Existing_Color_Handling,
	tick:                         int,
}

sweep_build :: proc(s: ^Sweep_State, e: ^engine.Engine) {
	s.color_handling = e.cfg.existing_color_handling
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
		engine.PARTICLE_FILTER_ALL_FILLS,
		.Top_Bottom_Left_Right,
	)
	defer delete(chars[:])
	reserve(&s.active, len(chars))
	s.first_frame_spans = make([dynamic]engine.Span, len(e.particles))
	s.second_frame_spans = make([dynamic]engine.Span, len(e.particles))
	s.start_ticks = make([dynamic]int, len(e.particles))
	s.active_phase = make([dynamic]i8, len(e.particles))
	for i in 0 ..< len(s.active_phase) {
		s.active_phase[i] = -1
		s.start_ticks[i] = -1
	}
	span_length := len(s.config.sweep_symbols) + 1
	// Both sweeps fill every column; no per-frame append or preliminary clear.
	non_zero_resize(&s.frames, len(chars) * span_length * 2)
	switch s.color_handling {
	case .Dynamic:
		for id in e.particle_sets.input {
			style := engine.get_initial_appearance(e, engine.Particle_Id(id))
			if fg, ok := style.colors.fg.?; ok do append(&s.dynamic_second_sweep_palette, fg)
			if bg, ok := style.colors.bg.?; ok do append(&s.dynamic_second_sweep_palette, bg)
		}
		if len(s.dynamic_second_sweep_palette) == 0 {
			append(&s.dynamic_second_sweep_palette, ..spectrum[:])
		}
	case .Ignore, .Always:
	}

	for id, i in chars {
		final: engine.Color_Pair
		switch s.color_handling {
		case .Dynamic:
			if (.Fill not_in e.particles.flags[id]) do final = engine.get_initial_appearance(e, engine.Particle_Id(id)).colors
		case .Ignore, .Always:
			if (.Fill in e.particles.flags[id]) {
				final = {
					fg = engine.Color{0x00, 0x00, 0x00},
					bg = nil,
				}
			} else {
				final = {
					fg = engine.gradient_sample(
						sampler,
						spectrum[:],
						e.particles.initial_coord[id],
					),
					bg = nil,
				}
			}
		}
		sym := e.particles.initial_symbol[engine.Particle_Id(id)]

		first_start := i * span_length * 2
		first := s.frames[first_start:first_start + span_length]
		for symbol, frame in s.config.sweep_symbols {
			gray := gray_shades[rand.int_max(5)]
			first.symbol[frame] = symbol
			first.appearance[frame] = engine.Appearance {
				colors = {fg = gray},
			}
			first.duration[frame] = 5
		}
		first.symbol[span_length - 1] = sym
		first.appearance[span_length - 1] = engine.Appearance {
			colors = {fg = gray_shades[1]},
		}
		first.duration[span_length - 1] = 1
		s.first_frame_spans[id] = {first_start, span_length}

		second_start := first_start + span_length
		second := s.frames[second_start:second_start + span_length]
		for symbol, frame in s.config.sweep_symbols {
			colors :=
				s.color_handling == .Dynamic ? s.dynamic_second_sweep_palette[:] : spectrum[:]
			col := colors[rand.int_max(len(colors))]
			second.symbol[frame] = symbol
			second.appearance[frame] = engine.Appearance {
				colors = {fg = col},
			}
			second.duration[frame] = 5
		}
		second.symbol[span_length - 1] = sym
		second.appearance[span_length - 1] = engine.Appearance {
			colors = final,
		}
		second.duration[span_length - 1] = 1
		s.second_frame_spans[id] = {second_start, span_length}
	}

	s.reveal.groups = engine.get_particles_grouped(
		engine.Particle_Query {
			e.particle_sets,
			e.particles.initial_coord[:len(e.particles)],
			e.canvas,
		},
		engine.PARTICLE_FILTER_ALL_FILLS,
		s.config.first_sweep_direction,
	)
	s.reveal.ease = .Circular_In_Out
	s.reveal.duration = 100
	s.second_groups = engine.get_particles_grouped(
		engine.Particle_Query {
			e.particle_sets,
			e.particles.initial_coord[:len(e.particles)],
			e.canvas,
		},
		engine.PARTICLE_FILTER_ALL_FILLS,
		s.config.second_sweep_direction,
	)
	s.first_phase = true
}

sweep_next :: proc(s: ^Sweep_State, e: ^engine.Engine) -> bool {
	if len(s.active) == 0 && s.complete {
		return false
	}
	change := engine.group_reveal_step(&s.reveal)
	for gi in change.added.start ..< change.added.start + change.added.len {
		for id in engine.group_members(s.reveal.groups, gi) {
			if s.first_phase {
				engine.set_particle(e, id, engine.Visible(true))
			}
			phase: i8 = 0
			if !s.first_phase {
				phase = 1
			}
			if s.active_phase[id] < 0 do append(&s.active, id)
			s.active_phase[id] = phase
			s.start_ticks[id] = s.tick
		}
	}
	if engine.group_reveal_complete(s.reveal) {
		if s.first_phase {
			engine.groups_delete(&s.reveal.groups)
			s.reveal.groups = s.second_groups
			engine.group_reveal_reset(&s.reveal)
			s.first_phase = false
		} else {
			s.complete = true
		}
	}
	write := 0
	for id in s.active {
		phase := s.active_phase[id]
		if phase < 0 do continue
		span := phase == 0 ? s.first_frame_spans[id] : s.second_frame_spans[id]
		age := s.tick - s.start_ticks[id]
		if age % 5 == 0 {
			frame := age / 5
			engine.set_symbol(e, id, s.frames[span.start + frame].symbol)
			engine.set_appearance(e, id, s.frames[span.start + frame].appearance)
		}
		if age + 1 == (span.len - 1) * 5 + 1 {
			s.active_phase[id] = -1
		} else {
			s.active[write] = id
			write += 1
		}
	}
	resize(&s.active, write)
	s.tick += 1
	return true
}
