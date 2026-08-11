package effects

import engine "../engine"

import "core:fmt"

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
	config:        Highlight_Config,
	scene_handles: [dynamic]int,
	easer:         engine.Sequence_Easer,
}

highlight_build :: proc(s: ^Highlight_State, e: ^engine.Engine) {
	groups := engine.get_characters_grouped(
		engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas},
		engine.filter_input(),
		s.config.highlight_direction,
	)
	s.easer.groups = groups
	s.easer.tracker = engine.Easing_Tracker {
		fn          = engine.ease_of(.Circular_In_Out),
		total_steps = 100,
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

	chars := engine.get_characters(
		engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas},
		engine.filter_input(),
		.Top_Bottom_Left_Right,
	)
	defer delete(chars[:])
	max_slot := 0
	for id in chars do max_slot = max(max_slot, int(id))
	s.scene_handles = make([dynamic]int, max_slot + 1)
	for i in 0 ..= max_slot do s.scene_handles[i] = -1

	for id in chars {
		c := e.chars.input_coord[id]
		base := engine.gradient_sample(sampler, spectrum[:], c)
		// base -> bright -> bright -> base with widths 3/width/3
		bright := engine.adjust_color_brightness(base, s.config.highlight_brightness)
		hl := engine.gradient_make(
			[]engine.Color{base, bright, bright, base},
			[]int{3, s.config.highlight_width, 3},
			false,
		)
		defer delete(hl[:])
		sc := engine.new_scene(e, false, .None, {})
		for color in hl {
			engine.scene_add_frame(&e.scenes[sc], e.chars.input_symbol[id], 2, color, nil, false)
		}
		s.scene_handles[id] = sc
		engine.set_appearance(&e.chars, id, e.chars.input_symbol[id], base, nil)
		e.chars.is_visible[id] = true
	}
}

highlight_next :: proc(s: ^Highlight_State, e: ^engine.Engine) -> bool {
	if len(e.active) == 0 && engine.seq_complete(s.easer) {
		return false
	}
	r := engine.seq_step(&s.easer)
	for gi in r.added_start ..< r.added_end {
		for id in engine.group_slice(s.easer.groups, gi) {
			engine.activate_scene(e, id, s.scene_handles[id])
			engine.active_insert(e, id)
		}
	}
	engine.update(e)
	engine.frame(e)
	return true
}
