package effects

import engine "../engine"

import "core:fmt"
import ease "core:math/ease"

// wipe — reveal characters along a grouped direction, eased.

Wipe_Config :: struct {
	wipe_direction:           engine.Character_Group,
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
	config:       Wipe_Config,
	final_colors: [dynamic]engine.Color_Pair,
	scenes:       [dynamic]engine.Scene,
	active:       [dynamic]engine.Char_Id,
	active_by_id: [dynamic]u8,
	reveal:       engine.Group_Reveal,
	wipe_delay:   int,
}

wipe_build :: proc(s: ^Wipe_State, e: ^engine.Engine) {
	groups := engine.get_characters_grouped(
		engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas},
		engine.filter_input(),
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

	chars := engine.get_characters(
		engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas},
		engine.filter_input(),
		.Top_Bottom_Left_Right,
	)
	defer delete(chars[:])
	max_slot := 0
	for id in chars do max_slot = max(max_slot, int(id))
	s.final_colors = make([dynamic]engine.Color_Pair, max_slot + 1)
	s.scenes = make([dynamic]engine.Scene, max_slot + 1)
	s.active_by_id = make([dynamic]u8, max_slot + 1)

	for id in chars {
		c := e.chars.input_coord[id]
		final := engine.Color_Pair {
			fg = engine.gradient_sample(sampler, spectrum[:], c),
			bg = nil,
		}
		s.final_colors[id] = final
		// wipe gradient from spectrum[0] to the final fg color
		wg := engine.gradient_make(
			[]engine.Color{spectrum[0], final.fg.?},
			s.config.final_gradient_steps[:],
			false,
		)
		defer delete(wg[:])
		engine.scene_add_gradient(
			&s.scenes[id],
			[]string{e.chars.input_symbol[id]},
			s.config.final_gradient_frames,
			wg[:],
			nil,
		)
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
				scene := &s.scenes[id]
				engine.character_set_visual(&e.chars, id, engine.scene_first_visual(scene^))
				e.chars.is_visible[id] = true
				if s.active_by_id[id] == 0 {
					s.active_by_id[id] = 1
					append(&s.active, id)
				}
			}
		}
		for gi in change.removed.start ..< change.removed.start + change.removed.len {
			for id in engine.group_members(s.reveal.groups, gi) {
				s.active_by_id[id] = 0
				engine.scene_reset(&s.scenes[id])
				e.chars.is_visible[id] = false
			}
		}
		s.wipe_delay = s.config.wipe_delay
	} else {
		s.wipe_delay -= 1
	}
	write := 0
	for id in s.active {
		if s.active_by_id[id] == 0 do continue
		visual, complete := engine.step_animation(&s.scenes[id])
		engine.character_set_visual(&e.chars, id, visual)
		if complete {
			s.active_by_id[id] = 0
		} else {
			s.active[write] = id
			write += 1
		}
	}
	resize(&s.active, write)
	engine.frame(e)
	return true
}
