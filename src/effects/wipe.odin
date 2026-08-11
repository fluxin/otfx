package effects

import engine "../engine"

import "core:fmt"

// wipe — reveal characters along a grouped direction, eased.

Wipe_Config :: struct {
	wipe_direction:           engine.Character_Group,
	wipe_delay:               int,
	wipe_ease:                engine.Easing,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_frames:    int,
	final_gradient_direction: engine.Gradient_Direction,
}

wipe_config_default :: proc() -> Wipe_Config {
	cfg := Wipe_Config {
		wipe_direction           = .Diagonal_TL2BR,
		wipe_ease                = engine.ease_of(.Circular_In_Out),
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
			if !parse_int_flag(&cfg.wipe_delay, args, &i, value, has_value) do return false
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
	config:        Wipe_Config,
	final_colors:  [dynamic]engine.Color_Pair,
	scene_handles: [dynamic]int,
	easer:         engine.Sequence_Easer,
	wipe_delay:    int,
}

wipe_build :: proc(s: ^Wipe_State, e: ^engine.Engine) {
	groups := engine.get_characters_grouped(
		engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas},
		engine.filter_input(),
		s.config.wipe_direction,
	)
	s.easer.groups = groups
	s.easer.tracker = engine.Easing_Tracker {
		fn          = s.config.wipe_ease,
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
	s.final_colors = make([dynamic]engine.Color_Pair, max_slot + 1)
	s.scene_handles = make([dynamic]int, max_slot + 1)
	for i in 0 ..= max_slot do s.scene_handles[i] = -1

	for id in chars {
		c := e.chars.input_coord[id]
		final := engine.Color_Pair {
			fg = engine.gradient_sample(sampler, spectrum[:], c),
			bg = nil,
		}
		s.final_colors[id] = final
		sc := engine.new_scene(e, false, .None, {})
		// wipe gradient from spectrum[0] to the final fg color
		wg := engine.gradient_make(
			[]engine.Color{spectrum[0], final.fg.?},
			s.config.final_gradient_steps[:],
			false,
		)
		defer delete(wg[:])
		engine.scene_add_gradient(
			&e.scenes[sc],
			[]string{e.chars.input_symbol[id]},
			s.config.final_gradient_frames,
			wg[:],
			nil,
		)
		s.scene_handles[id] = sc
	}
	s.wipe_delay = s.config.wipe_delay
}

wipe_next :: proc(s: ^Wipe_State, e: ^engine.Engine) -> bool {
	if len(e.active) == 0 && engine.seq_complete(s.easer) {
		return false
	}
	if s.wipe_delay == 0 {
		r := engine.seq_step(&s.easer)
		for gi in r.added_start ..< r.added_end {
			for id in engine.group_slice(s.easer.groups, gi) {
				engine.activate_scene(e, id, s.scene_handles[id])
				e.chars.is_visible[id] = true
				engine.active_insert(e, id)
			}
		}
		for gi in r.removed_start ..< r.removed_end {
			for id in engine.group_slice(s.easer.groups, gi) {
				e.chars.active_scene[id] = -1
				engine.scene_reset(&e.scenes[s.scene_handles[id]])
				e.chars.is_visible[id] = false
			}
		}
		s.wipe_delay = s.config.wipe_delay
	} else {
		s.wipe_delay -= 1
	}
	engine.update(e)
	engine.frame(e)
	return true
}
