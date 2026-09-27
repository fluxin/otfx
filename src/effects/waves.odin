package effects

import "../engine"

import "core:fmt"
import "core:math/ease"

// waves — one shared eased wave timeline, staggered by group start ticks, then
// a direct per-character transition into the final gradient.

Waves_Config :: struct {
	wave_symbols:             [dynamic]rune,
	wave_gradient_stops:      [dynamic]engine.Color,
	wave_gradient_steps:      [dynamic]int,
	wave_count:               int,
	wave_length:              int,
	wave_direction:           engine.Particle_Group,
	wave_easing:              ease.Ease,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

waves_config_default :: proc() -> Waves_Config {
	cfg := Waves_Config {
		wave_count               = 7,
		wave_length              = 2,
		wave_direction           = .Column_L2R,
		wave_easing              = .Sine_In_Out,
		final_gradient_direction = .Diagonal,
	}
	append(
		&cfg.wave_symbols,
		..[]rune {
			'▁',
			'▂',
			'▃',
			'▄',
			'▅',
			'▆',
			'▇',
			'█',
			'▇',
			'▆',
			'▅',
			'▄',
			'▃',
			'▂',
			'▁',
		},
	)
	append(
		&cfg.wave_gradient_stops,
		..[]engine.Color {
			engine.Color{0xf0, 0xff, 0x65},
			engine.Color{0xff, 0xb1, 0x02},
			engine.Color{0x31, 0xa0, 0xd4},
			engine.Color{0xff, 0xb1, 0x02},
			engine.Color{0xf0, 0xff, 0x65},
		},
	)
	append(&cfg.wave_gradient_steps, 6)
	append(
		&cfg.final_gradient_stops,
		..[]engine.Color {
			engine.Color{0xff, 0xb1, 0x02},
			engine.Color{0x31, 0xa0, 0xd4},
			engine.Color{0xf0, 0xff, 0x65},
		},
	)
	append(&cfg.final_gradient_steps, 12)
	return cfg
}

waves_parse :: proc(cfg: ^Waves_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--wave-symbols":
			if !parse_symbols_flag(&cfg.wave_symbols, args, &i, value, has_value) do return false
		case "--wave-gradient-stops":
			if !parse_colors_flag(&cfg.wave_gradient_stops, args, &i, value, has_value) do return false
		case "--wave-gradient-steps":
			if !parse_ints_flag(&cfg.wave_gradient_steps, args, &i, value, has_value) do return false
		case "--wave-count":
			if !parse_int_flag(&cfg.wave_count, args, &i, value, has_value) do return false
		case "--wave-length":
			if !parse_int_flag(&cfg.wave_length, args, &i, value, has_value) do return false
		case "--wave-direction":
			if !parse_group_flag(&cfg.wave_direction, args, &i, value, has_value) do return false
		case "--wave-easing":
			if !parse_ease_flag(&cfg.wave_easing, args, &i, value, has_value) do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown waves option: ", name)
			return false
		}
	}
	return true
}

Waves_State :: struct {
	config:         Waves_Config,
	pending_cols:   engine.Particle_Groups,
	wave_symbols:   [dynamic]rune,
	wave_codes:     [dynamic]engine.Appearance_Id, // age -> shared appearance
	last_wave:      engine.Color,
	final_index:    [dynamic]int, // spectrum index by Particle_Id
	fades:          engine.Gradient_Steps, // fades to each spectrum entry
	start_ticks:    [dynamic]int, // -1 pending, -2 complete
	final_step:     [dynamic]int, // -1 until the final appearance is published
	active:         [dynamic]engine.Particle_Id, // revealed, not yet complete
	col_idx:        int,
	tick:           int,
	wave_ticks:     int,
	color_handling: engine.Existing_Color_Handling,
}

waves_build :: proc(s: ^Waves_State, e: ^engine.Engine) {
	final_spectrum := engine.gradient_make(
		s.config.final_gradient_stops[:],
		s.config.final_gradient_steps[:],
		false,
	)
	defer delete(final_spectrum[:])
	final_sampler := engine.gradient_sampler(
		e.canvas.text_bottom,
		e.canvas.text_top,
		e.canvas.text_left,
		e.canvas.text_right,
		s.config.final_gradient_direction,
	)
	wave_spectrum := engine.gradient_make(
		s.config.wave_gradient_stops[:],
		s.config.wave_gradient_steps[:],
		false,
	)
	defer delete(wave_spectrum[:])
	entries := max(len(wave_spectrum), len(s.config.wave_symbols))
	colors := engine.sequence_expand(wave_spectrum[:], entries)
	symbols := engine.sequence_expand(s.config.wave_symbols[:], entries)
	defer delete(colors)
	defer delete(symbols)
	// Resolve the eased timeline into separate glyph and shared-appearance lanes.
	cycle := make([]engine.Appearance_Id, entries)
	defer delete(cycle)
	for _, i in symbols {
		cycle[i] = engine.prepare_appearance(e, engine.Appearance{colors = {fg = colors[i]}})
	}
	wave_frames := entries * s.config.wave_count
	wave_length := max(s.config.wave_length, 1)
	s.wave_ticks = wave_frames * wave_length
	s.last_wave = colors[entries - 1]
	s.wave_symbols = make([dynamic]rune, max(s.wave_ticks - 1, 0))
	s.wave_codes = make([dynamic]engine.Appearance_Id, max(s.wave_ticks - 1, 0))
	for age in 0 ..< len(s.wave_codes) {
		eased := engine.eased_timeline_index(age, s.wave_ticks, s.config.wave_easing)
		frame := min(eased / wave_length, wave_frames - 1)
		s.wave_symbols[age] = symbols[frame % entries]
		s.wave_codes[age] = cycle[frame % entries]
	}

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
	initial_coords := e.particles.initial_coord[:len(e.particles)]
	visible_flags := e.particles.flags
	s.final_index = make([dynamic]int, len(e.particles))
	s.fades = engine.gradient_steps_make(
		e,
		s.last_wave,
		final_spectrum[:],
		s.config.final_gradient_steps[0],
	)
	s.color_handling = e.cfg.existing_color_handling
	s.start_ticks = make([dynamic]int, len(e.particles))
	for i in 0 ..< len(s.start_ticks) do s.start_ticks[i] = -1
	s.final_step = make([dynamic]int, len(e.particles))
	for i in 0 ..< len(s.final_step) do s.final_step[i] = -1
	reserve(&s.active, len(e.particles))
	for id in chars {
		c := initial_coords[id]
		s.final_index[id] = engine.gradient_sample_index(final_sampler, len(final_spectrum), c)
		visible_flags[id] -= {.Visible}
	}

	s.pending_cols = engine.get_particles_grouped(
		engine.Particle_Query {
			e.particle_sets,
			e.particles.initial_coord[:len(e.particles)],
			e.canvas,
		},
		engine.PARTICLE_FILTER_INPUT,
		s.config.wave_direction,
	)
}

waves_next :: proc(s: ^Waves_State, e: ^engine.Engine) -> bool #no_bounds_check {
	group_count := len(s.pending_cols.spans)
	if s.col_idx >= group_count && len(s.active) == 0 {
		return false
	}
	if s.col_idx < group_count {
		for id in engine.group_members(s.pending_cols, s.col_idx) {
			engine.set_particle(e, id, engine.Visible(true))
			s.start_ticks[id] = s.tick
			append(&s.active, id)
		}
		s.col_idx += 1
	}

	wave_ticks := s.wave_ticks
	assert(wave_ticks >= 1 && len(s.config.final_gradient_steps) > 0)
	final_steps := s.config.final_gradient_steps[0]
	last_wave := s.last_wave
	// Completed characters leave the active list, so a frame's work is bounded
	// by what is actually animating rather than the whole population.
	write := 0
	for id in s.active {
		age := s.tick - s.start_ticks[id]
		if age < wave_ticks - 1 {
			if age == 0 || s.wave_symbols[age] != s.wave_symbols[age - 1] do engine.set_symbol(e, id, s.wave_symbols[age])
			if age == 0 || s.wave_codes[age] != s.wave_codes[age - 1] do engine.set_appearance(e, id, s.wave_codes[age])
		} else {
			final_age := age - (wave_ticks - 1)
			final_ticks := (final_steps + 1) * 10
			step := final_age == 0 ? 0 : min((final_age - 1) / 10, final_steps)
			if s.color_handling != .Dynamic {
				if step != s.final_step[id] {
					engine.set_symbol(e, id, e.particles.initial_symbol[id])
					engine.set_appearance(e, id, engine.gradient_step(s.fades, s.final_index[id], step))
					s.final_step[id] = step
				}
			} else {
				style := engine.get_initial_appearance(e, engine.Particle_Id(id))
				if style.colors.fg == nil && style.colors.bg == nil {
					final_ticks = 10
					step = 0
				}
				if step != s.final_step[id] {
					appearance := engine.Appearance{}
					if style.colors.fg != nil || style.colors.bg != nil {
						engine.dynamic_gradient_to_input(
							&appearance,
							last_wave,
							style,
							final_steps,
							step,
						)
					}
					engine.set_symbol(e, id, e.particles.initial_symbol[id])
					engine.set_appearance(e, id, appearance)
					s.final_step[id] = step
				}
			}
			if final_age == final_ticks {
				s.start_ticks[id] = -2
				continue
			}
		}
		s.active[write] = id
		write += 1
	}
	resize(&s.active, write)
	s.tick += 1
	return true
}
