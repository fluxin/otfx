package effects

import engine "../engine"

import "core:fmt"

// waves — one shared eased wave timeline, staggered by group start ticks, then
// a direct per-character transition into the final gradient.

Waves_Config :: struct {
	wave_symbols:             [dynamic]string,
	wave_gradient_stops:      [dynamic]engine.Color,
	wave_gradient_steps:      [dynamic]int,
	wave_count:               int,
	wave_length:              int,
	wave_direction:           engine.Character_Group,
	wave_easing:              engine.Easing,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

waves_config_default :: proc() -> Waves_Config {
	cfg := Waves_Config {
		wave_count               = 7,
		wave_length              = 2,
		wave_direction           = .Column_L2R,
		wave_easing              = engine.ease_of(.Sine_In_Out),
		final_gradient_direction = .Diagonal,
	}
	append(
		&cfg.wave_symbols,
		..[]string {
			"▁",
			"▂",
			"▃",
			"▄",
			"▅",
			"▆",
			"▇",
			"█",
			"▇",
			"▆",
			"▅",
			"▄",
			"▃",
			"▂",
			"▁",
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
	config:        Waves_Config,
	pending_cols:  engine.Char_Groups,
	wave_spectrum: [dynamic]engine.Color,
	wave_colors:   [dynamic]engine.Color,
	wave_symbols:  [dynamic]string,
	final_colors:  [dynamic]engine.Color, // indexed by Char_Id
	start_ticks:   [dynamic]int, // -1 pending, -2 complete
	revealed:      [dynamic]engine.Char_Id,
	col_idx:       int,
	tick:          int,
	active_count:  int,
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
	s.wave_spectrum = engine.gradient_make(
		s.config.wave_gradient_stops[:],
		s.config.wave_gradient_steps[:],
		false,
	)
	wave_frames := len(s.wave_spectrum) * s.config.wave_count
	s.wave_colors = make([dynamic]engine.Color, wave_frames)
	s.wave_symbols = make([dynamic]string, wave_frames)
	color_index, symbol_index := 0, 0
	for i in 0 ..< wave_frames {
		s.wave_colors[i] = s.wave_spectrum[color_index]
		s.wave_symbols[i] = s.config.wave_symbols[symbol_index]
		color_index += 1
		if color_index == len(s.wave_spectrum) do color_index = 0
		symbol_index += 1
		if symbol_index == len(s.config.wave_symbols) do symbol_index = 0
	}

	chars := engine.get_characters(
		engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas},
		engine.filter_input(),
		.Top_Bottom_Left_Right,
	)
	defer delete(chars[:])
	input_coords := e.chars.input_coord[:]
	visible := e.chars.is_visible
	s.final_colors = make([dynamic]engine.Color, len(e.chars))
	s.start_ticks = make([dynamic]int, len(e.chars))
	for i in 0 ..< len(s.start_ticks) do s.start_ticks[i] = -1
	for id in chars {
		c := input_coords[id]
		s.final_colors[id] = engine.gradient_sample(final_sampler, final_spectrum[:], c)
		visible[id] = false
	}

	s.pending_cols = engine.get_characters_grouped(
		engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas},
		engine.filter_input(),
		s.config.wave_direction,
	)
}

waves_next :: proc(s: ^Waves_State, e: ^engine.Engine) -> bool {
	group_count := engine.group_count(s.pending_cols)
	if s.col_idx >= group_count && s.active_count == 0 {
		return false
	}
	visible := e.chars.is_visible
	if s.col_idx < group_count {
		for id in engine.group_slice(s.pending_cols, s.col_idx) {
			visible[id] = true
			s.start_ticks[id] = s.tick
			append(&s.revealed, id)
			s.active_count += 1
		}
		s.col_idx += 1
	}

	wave_length := max(s.config.wave_length, 1)
	wave_frames := len(s.wave_colors)
	wave_ticks := wave_frames * wave_length
	assert(wave_ticks >= 1 && len(s.config.final_gradient_steps) > 0)
	final_steps := s.config.final_gradient_steps[0]
	final_ticks := (final_steps + 1) * 10
	last_wave := s.wave_colors[wave_frames - 1]
	input_symbols := e.chars.input_symbol
	visual_symbols := e.chars.visual_symbol
	visual_fg := e.chars.visual_fg
	for id in e.character_sets.input {
		start_tick := s.start_ticks[id]
		if start_tick < 0 do continue
		age := s.tick - start_tick
		if age < wave_ticks - 1 {
			eased_tick := engine.eased_timeline_index(age, wave_ticks, s.config.wave_easing)
			frame_index := eased_tick / wave_length
			visual_symbols[id] = s.wave_symbols[frame_index]
			visual_fg[id] = s.wave_colors[frame_index]
		} else {
			final_age := age - (wave_ticks - 1)
			final_step := final_age == 0 ? 0 : min((final_age - 1) / 10, final_steps)
			visual_symbols[id] = input_symbols[id]
			visual_fg[id] = engine.gradient_between_step(
				last_wave,
				s.final_colors[id],
				final_steps,
				final_step,
			)
			if final_age == final_ticks {
				s.start_ticks[id] = -2
				s.active_count -= 1
			}
		}
	}
	s.tick += 1
	engine.frame(e, s.revealed[:])
	return true
}
