package effects

import "../engine"

import "core:fmt"
import "core:math/ease"

// highlight — a specular highlight sweeps across the text.

Highlight_Config :: struct {
	highlight_brightness:     f64,
	highlight_direction:      engine.Character_Group,
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
			if !parse_float_flag(&cfg.highlight_brightness, args, &i, value, has_value) do return false
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
	config:       Highlight_Config,
	reveal:       engine.Group_Reveal,
	characters:   [dynamic]engine.Char_Id,
	index_by_id:  [dynamic]int,
	palette:      [dynamic]engine.Color,
	start_ticks:  [dynamic]int,
	active_slots: [dynamic]int,
	palette_len:  int,
	tick:         int,
}

highlight_build :: proc(s: ^Highlight_State, e: ^engine.Engine) {
	groups := engine.get_characters_grouped(
		engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas},
		engine.CHAR_FILTER_INPUT,
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

	s.characters = engine.get_characters(
		engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas},
		engine.CHAR_FILTER_INPUT,
		.Top_Bottom_Left_Right,
	)
	s.index_by_id = make([dynamic]int, len(e.chars))
	s.start_ticks = make([dynamic]int, len(e.chars))
	for i in 0 ..< len(s.start_ticks) do s.start_ticks[i] = -1
	for id, i in s.characters {
		s.index_by_id[id] = i
		c := e.chars.input_coord[id]
		base := engine.gradient_sample(sampler, spectrum[:], c)
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
		engine.character_set_visual(&e.chars, id, {symbol = e.chars.input_symbol[id], fg = base})
		e.chars.is_visible[id] = true
	}
}

highlight_next :: proc(s: ^Highlight_State, e: ^engine.Engine) -> ([]engine.Char_Id, bool) {
	if len(s.active_slots) == 0 && engine.group_reveal_complete(s.reveal) {
		return nil, false
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
		if age >= s.palette_len * 2 do continue
		id := s.characters[slot]
		e.chars.visual[id].fg = s.palette[slot * s.palette_len + age / 2]
		if age + 1 < s.palette_len * 2 {s.active_slots[write] = slot; write += 1}
	}
	resize(&s.active_slots, write)
	s.tick += 1
	return nil, true
}
