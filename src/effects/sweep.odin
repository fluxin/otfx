package effects

import "../engine"
import "core:math/ease"
import "core:math/rand"

import "core:fmt"

// sweep — a gray shimmer sweeps across the whole canvas, then a colored sweep
// lands the final gradient.

Sweep_Config :: struct {
	sweep_symbols:            [dynamic]string,
	first_sweep_direction:    engine.Character_Group,
	second_sweep_direction:   engine.Character_Group,
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
	append(&cfg.sweep_symbols, ..[]string{"█", "▓", "▒", "░"})
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
	active:                       [dynamic]engine.Char_Id,
	active_phase:                 [dynamic]i8, // -1 inactive, 0 first lane, 1 second lane
	reveal:                       engine.Group_Reveal,
	second_groups:                engine.Char_Groups,
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

	chars := engine.get_characters(
		engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas},
		engine.CHAR_FILTER_ALL_FILLS,
		.Top_Bottom_Left_Right,
	)
	defer delete(chars[:])
	s.first_frame_spans = make([dynamic]engine.Span, len(e.chars))
	s.second_frame_spans = make([dynamic]engine.Span, len(e.chars))
	s.start_ticks = make([dynamic]int, len(e.chars))
	s.active_phase = make([dynamic]i8, len(e.chars))
	for i in 0 ..< len(s.active_phase) {
		s.active_phase[i] = -1
		s.start_ticks[i] = -1
	}
	reserve(&s.frames, len(chars) * (len(s.config.sweep_symbols) + 1) * 2)
	switch s.color_handling {
	case .Dynamic:
		for id in e.character_sets.input {
			style := e.chars.input_style[id]
			if fg, ok := style.fg.?; ok do append(&s.dynamic_second_sweep_palette, fg)
			if bg, ok := style.bg.?; ok do append(&s.dynamic_second_sweep_palette, bg)
		}
		if len(s.dynamic_second_sweep_palette) == 0 {
			append(&s.dynamic_second_sweep_palette, ..spectrum[:])
		}
	case .Ignore, .Always:
	}

	for id in chars {
		final: engine.Color_Pair
		switch s.color_handling {
		case .Dynamic:
			if !e.chars.is_fill[id] do final = {e.chars.input_style[id].fg, e.chars.input_style[id].bg}
		case .Ignore, .Always:
			if e.chars.is_fill[id] {
				final = {
					fg = engine.Color{0x00, 0x00, 0x00},
					bg = nil,
				}
			} else {
				final = {
					fg = engine.gradient_sample(sampler, spectrum[:], e.chars.input_coord[id]),
					bg = nil,
				}
			}
		}
		sym := e.chars.input_symbol[id]

		first_start := len(s.frames)
		for symbol in s.config.sweep_symbols {
			gray := gray_shades[rand.int_max(5)]
			engine.timeline_append_frame(&s.frames, {symbol, gray, nil, false}, 5)
		}
		engine.timeline_append_frame(&s.frames, {sym, gray_shades[1], nil, false}, 1)
		s.first_frame_spans[id] = {first_start, len(s.config.sweep_symbols) + 1}

		second_start := len(s.frames)
		for symbol in s.config.sweep_symbols {
			colors :=
				s.color_handling == .Dynamic ? s.dynamic_second_sweep_palette[:] : spectrum[:]
			col := colors[rand.int_max(len(colors))]
			engine.timeline_append_frame(&s.frames, {symbol, col, nil, false}, 5)
		}
		engine.timeline_append_frame(&s.frames, {sym, final.fg, final.bg, false}, 1)
		s.second_frame_spans[id] = {second_start, len(s.config.sweep_symbols) + 1}
	}

	s.reveal.groups = engine.get_characters_grouped(
		engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas},
		engine.CHAR_FILTER_ALL_FILLS,
		s.config.first_sweep_direction,
	)
	s.reveal.ease = .Circular_In_Out
	s.reveal.duration = 100
	s.second_groups = engine.get_characters_grouped(
		engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas},
		engine.CHAR_FILTER_ALL_FILLS,
		s.config.second_sweep_direction,
	)
	s.first_phase = true
}

sweep_next :: proc(s: ^Sweep_State, e: ^engine.Engine) -> ([]engine.Char_Id, bool) {
	if len(s.active) == 0 && s.complete {
		return nil, false
	}
	change := engine.group_reveal_step(&s.reveal)
	for gi in change.added.start ..< change.added.start + change.added.len {
		for id in engine.group_members(s.reveal.groups, gi) {
			if s.first_phase do e.chars.is_visible[id] = true
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
		frame := age / 5
		e.chars.visual[id] = s.frames[span.start + frame].visual
		if age + 1 == (span.len - 1) * 5 + 1 {
			s.active_phase[id] = -1
		} else {
			s.active[write] = id
			write += 1
		}
	}
	resize(&s.active, write)
	s.tick += 1
	return nil, true
}
