package effects

import "../engine"

import "core:fmt"
import "core:math/ease"

// highlight — a specular highlight sweeps across the text.

Highlight_Config :: struct {
	highlight_brightness:     f64,
	highlight_direction:      engine.Particle_Group,
	highlight_width:          int,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

highlight_config_default :: proc() -> Highlight_Config {
	cfg := Highlight_Config {
		highlight_brightness     = 1.75,
		highlight_direction      = .Diagonal_BL2TR,
		highlight_width          = 8,
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

highlight_parse :: proc(cfg: ^Highlight_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--highlight-brightness":
			if !parse_float_flag(&cfg.highlight_brightness, args, &i, value, has_value) || cfg.highlight_brightness <= 0 do return false
		case "--highlight-direction":
			if !parse_group_flag(&cfg.highlight_direction, args, &i, value, has_value) do return false
		case "--highlight-width":
			if !parse_int_flag(&cfg.highlight_width, args, &i, value, has_value) do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown highlight option: ", name)
			return false
		}
	}
	return true
}

Highlight_State :: struct {
	config:         Highlight_Config,
	reveal:         engine.Group_Reveal,
	characters:     [dynamic]engine.Particle_Id,
	index_by_id:    [dynamic]int,
	palette:        [dynamic]engine.Color,
	start_ticks:    [dynamic]int,
	active_slots:   [dynamic]int,
	palette_len:    int,
	tick:           int,
	color_handling: engine.Existing_Color_Handling,
}

highlight_build :: proc(s: ^Highlight_State, e: ^engine.Engine) {
	groups := engine.get_particles_grouped(
		engine.Particle_Query {
			e.particle_sets,
			e.particles.initial_coord[:len(e.particles)],
			e.canvas,
		},
		engine.PARTICLE_FILTER_INPUT,
		s.config.highlight_direction,
	)
	s.reveal = engine.Group_Reveal {
		groups   = groups,
		ease     = .Circular_In_Out,
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

	s.characters = engine.get_particles(
		engine.Particle_Query {
			e.particle_sets,
			e.particles.initial_coord[:len(e.particles)],
			e.canvas,
		},
		engine.PARTICLE_FILTER_INPUT,
		.Top_Bottom_Left_Right,
	)
	s.color_handling = e.cfg.existing_color_handling
	reserve(&s.active_slots, len(s.characters))
	s.index_by_id = make([dynamic]int, len(e.particles))
	s.start_ticks = make([dynamic]int, len(e.particles))
	for i in 0 ..< len(s.start_ticks) do s.start_ticks[i] = -1
	for id, i in s.characters {
		s.index_by_id[id] = i
		c := e.particles.initial_coord[id]
		base := engine.gradient_sample(sampler, spectrum[:], c)
		if s.color_handling == .Dynamic {
			if fg, ok := engine.get_initial_appearance(e, engine.Particle_Id(id)).colors.fg.?; ok do base = fg
		}
		// base -> bright -> bright -> base with widths 3/width/3
		bright := engine.adjust_color_brightness(base, s.config.highlight_brightness)
		hl := engine.gradient_make(
			[]engine.Color{base, bright, bright, base},
			[]int{3, s.config.highlight_width, 3},
			false,
		)
		if i == 0 do s.palette_len = len(hl)
		append(&s.palette, ..hl[:])
		delete(hl[:])
		engine.set_symbol(e, id, e.particles.initial_symbol[engine.Particle_Id(id)])
		engine.set_appearance(
			e,
			id,
			engine.Appearance {
				colors = {
					fg = s.color_handling == .Dynamic ? engine.get_initial_appearance(e, engine.Particle_Id(id)).colors.fg : base,
					bg = s.color_handling == .Dynamic ? engine.get_initial_appearance(e, engine.Particle_Id(id)).colors.bg : nil,
				},
			},
		)
		e.particles.flags[id] += {.Visible}
	}
}

highlight_next :: proc(s: ^Highlight_State, e: ^engine.Engine) -> bool #no_bounds_check {
	if len(s.active_slots) == 0 && engine.group_reveal_complete(s.reveal) {
		return false
	}
	change := engine.group_reveal_step(&s.reveal)
	for gi in change.added.start ..< change.added.start + change.added.len {
		for id in engine.group_members(s.reveal.groups, gi) {
			slot := s.index_by_id[id]
			s.start_ticks[slot] = s.tick
			append(&s.active_slots, slot)
		}
	}
	write := 0
	for slot in s.active_slots {
		age := s.tick - s.start_ticks[slot]
		id := s.characters[slot]
		limit := s.palette_len * 2
		if s.color_handling == .Dynamic && engine.get_initial_appearance(e, engine.Particle_Id(id)).colors.fg == nil do limit = 2
		if age >= limit do continue
		if age % 2 == 0 {
			if s.color_handling == .Dynamic {
				style := engine.get_initial_appearance(e, engine.Particle_Id(id))
				if style.colors.fg != nil {
					engine.set_foreground(e, id, s.palette[slot * s.palette_len + age / 2])
				}
				engine.set_background(e, id, style.colors.bg)
			} else {
				engine.set_foreground(e, id, s.palette[slot * s.palette_len + age / 2])
			}
		}
		if age + 1 < limit {s.active_slots[write] = slot; write += 1}
	}
	resize(&s.active_slots, write)
	s.tick += 1
	return true
}
