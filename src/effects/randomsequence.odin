package effects

import "../engine"

import "core:fmt"

// randomsequence — characters reveal at random positions in a blur-to-focus
// gradient.

Randomsequence_Config :: struct {
	speed:                    f64,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_frames:    int,
	final_gradient_direction: engine.Gradient_Direction,
}

randomsequence_config_default :: proc() -> Randomsequence_Config {
	cfg := Randomsequence_Config {
		speed                    = 0.007,
		final_gradient_frames    = 8,
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

randomsequence_parse :: proc(cfg: ^Randomsequence_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--speed":
			if !parse_float_flag(&cfg.speed, args, &i, value, has_value) || cfg.speed <= 0 do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-frames":
			if !parse_int_flag(&cfg.final_gradient_frames, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown randomsequence option: ", name)
			return false
		}
	}
	return true
}

Randomsequence_State :: struct {
	config:         Randomsequence_Config,
	characters:     [dynamic]engine.Particle_Id,
	index_by_id:    [dynamic]int,
	fades:          engine.Appearance_Ramp,
	fade_index:     [dynamic]int,
	life_steps:     [dynamic]u8,
	start_ticks:    [dynamic]int,
	active_slots:   [dynamic]int,
	pending:        [dynamic]engine.Particle_Id,
	chars_per_tick: int,
	color_handling: engine.Existing_Color_Handling,
	tick:           int,
}

randomsequence_build :: proc(s: ^Randomsequence_State, e: ^engine.Engine) {
	s.chars_per_tick = max(int(s.config.speed * f64(len(e.particle_sets.input))), 1)
	s.color_handling = e.cfg.existing_color_handling

	chars := engine.get_particles(
		engine.Particle_Query {
			e.particle_sets,
			e.particles.initial_coord[:len(e.particles)],
			e.canvas,
		},
		engine.PARTICLE_FILTER_INPUT,
		.Top_Bottom_Left_Right,
	)
	s.characters = chars
	n := len(chars)
	reserve(&s.active_slots, n)
	reserve(&s.pending, n)
	s.index_by_id = make([dynamic]int, len(e.particles))
	s.start_ticks = make([dynamic]int, n)
	s.life_steps = make([dynamic]u8, n)
	for i in 0 ..< n do s.start_ticks[i] = -1
	if n == 0 do return

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
	bg := e.cfg.terminal_background_color

	base_tweens := make([]engine.Tween(engine.Appearance), n, context.temp_allocator)
	defer delete(base_tweens, context.temp_allocator)

	for id, slot in chars {
		s.index_by_id[id] = slot
		e.particles.flags[id] -= {.Visible}
		append(&s.pending, id)
		if s.color_handling == .Dynamic {
			style := engine.get_initial_appearance(e, id)
			if style.colors.fg != nil || style.colors.bg != nil {
				s.life_steps[slot] = 8
				base_tweens[slot] = {
					from = {colors = {bg, bg}},
					to   = {colors = style.colors},
				}
			} else {
				s.life_steps[slot] = 9
				// Sentinel `from.bold = true` distinguishes uncolored dynamic from styled gray.
				base_tweens[slot] = {
					from = {colors = {fg = bg}, bold = true},
					to   = {colors = {fg = engine.Color{0x80, 0x80, 0x80}}},
				}
			}
		} else {
			s.life_steps[slot] = 8
			final := engine.gradient_sample(sampler, spectrum[:], e.particles.initial_coord[id])
			base_tweens[slot] = {
				from = {colors = {fg = bg}},
				to   = {colors = {fg = final}},
			}
		}
	}

	unique_tweens: [dynamic]engine.Tween(engine.Appearance)
	unique_tweens, s.fade_index = engine.group_values(base_tweens)
	defer delete(unique_tweens)
	styles := make([]engine.Appearance, len(unique_tweens) * 9, context.temp_allocator)
	defer delete(styles, context.temp_allocator)
	for tw, row in unique_tweens {
		for step in 0 ..= 7 {
			styles[row * 9 + step] = {
				colors = engine.tween(tw.from.colors, tw.to.colors, 7, step),
			}
		}
		styles[row * 9 + 8] = tw.from.bold ? engine.Appearance{} : styles[row * 9 + 7]
	}
	s.fades = engine.ramp_from_styles(e, styles, 8)

	engine.random_shuffle(s.pending[:])
}

randomsequence_next :: proc(s: ^Randomsequence_State, e: ^engine.Engine) -> bool #no_bounds_check {
	if len(s.pending) == 0 && len(s.active_slots) == 0 {
		return false
	}
	for _ in 0 ..< s.chars_per_tick {
		if len(s.pending) == 0 do break
		next := pop(&s.pending)
		engine.set_visible(e, next, true)
		slot := s.index_by_id[next]
		s.start_ticks[slot] = s.tick
		append(&s.active_slots, slot)
		engine.set_symbol(e, next, e.particles.initial_symbol[next])
	}
	frames := s.config.final_gradient_frames
	write := 0
	for slot in s.active_slots {
		age := s.tick - s.start_ticks[slot]
		id := s.characters[slot]
		life := int(s.life_steps[slot]) * frames
		if age % frames == 0 {
			step := min(age / frames, 8)
			engine.set_appearance(e, id, engine.ramp_code(s.fades, s.fade_index[slot], step))
		}
		if age + 1 < life {
			s.active_slots[write] = slot
			write += 1
		}
	}
	resize(&s.active_slots, write)
	s.tick += 1
	return true
}
