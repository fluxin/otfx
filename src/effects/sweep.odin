package effects

import engine "../engine"
import ease "core:math/ease"
import rand "core:math/rand"

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
	config:        Sweep_Config,
	final_colors:  [dynamic]engine.Color_Pair,
	first_scenes:  [dynamic]engine.Scene,
	second_scenes: [dynamic]engine.Scene,
	active:        [dynamic]engine.Char_Id,
	active_phase:  [dynamic]i8, // -1 inactive, 0 first scene, 1 second scene
	reveal:        engine.Group_Reveal,
	second_groups: engine.Char_Groups,
	first_phase:   bool,
	complete:      bool,
}

sweep_build :: proc(s: ^Sweep_State, e: ^engine.Engine) {
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
	max_slot := 0
	for id in chars do max_slot = max(max_slot, int(id))
	s.final_colors = make([dynamic]engine.Color_Pair, max_slot + 1)
	s.first_scenes = make([dynamic]engine.Scene, max_slot + 1)
	s.second_scenes = make([dynamic]engine.Scene, max_slot + 1)
	s.active_phase = make([dynamic]i8, max_slot + 1)
	for i in 0 ..= max_slot do s.active_phase[i] = -1

	for id in chars {
		c := e.chars.input_coord[id]
		is_fill := e.chars.is_fill[id]
		if is_fill {
			s.final_colors[id] = engine.Color_Pair {
				fg = engine.Color{0x00, 0x00, 0x00},
				bg = nil,
			}
		} else {
			s.final_colors[id] = engine.Color_Pair {
				fg = engine.gradient_sample(sampler, spectrum[:], c),
				bg = nil,
			}
		}
		sym := e.chars.input_symbol[id]

		// initial sweep: gray shimmer then a neutral final frame
		for symbol in s.config.sweep_symbols {
			gray := gray_shades[rand.int_max(5)]
			engine.scene_add_frame(&s.first_scenes[id], symbol, 5, gray, nil, false)
		}
		engine.scene_add_frame(&s.first_scenes[id], sym, 1, gray_shades[1], nil, false)

		// second sweep: final gradient colors then the final frame
		for symbol in s.config.sweep_symbols {
			col := spectrum[rand.int_max(len(spectrum))]
			engine.scene_add_frame(&s.second_scenes[id], symbol, 5, col, nil, false)
		}
		engine.scene_add_frame(&s.second_scenes[id], sym, 1, s.final_colors[id].fg, nil, false)
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

sweep_next :: proc(s: ^Sweep_State, e: ^engine.Engine) -> bool {
	if len(s.active) == 0 && s.complete {
		return false
	}
	change := engine.group_reveal_step(&s.reveal)
	for gi in change.added.start ..< change.added.start + change.added.len {
		for id in engine.group_members(s.reveal.groups, gi) {
			if s.first_phase do e.chars.is_visible[id] = true
			phase: i8 = 0
			scene := &s.first_scenes[id]
			if !s.first_phase {
				phase = 1
				scene = &s.second_scenes[id]
			}
			engine.character_set_visual(&e.chars, id, engine.scene_first_visual(scene^))
			if s.active_phase[id] < 0 do append(&s.active, id)
			s.active_phase[id] = phase
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
		scene := phase == 0 ? &s.first_scenes[id] : &s.second_scenes[id]
		visual, scene_complete := engine.step_animation(scene)
		engine.character_set_visual(&e.chars, id, visual)
		if scene_complete {
			s.active_phase[id] = -1
		} else {
			s.active[write] = id
			write += 1
		}
	}
	resize(&s.active, write)
	engine.frame(e)
	return true
}
