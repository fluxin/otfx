package effects

import engine "../engine"
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
	scene_handles: [dynamic]int, // initial_sweep per slot
	second_scenes: [dynamic]int, // second_sweep per slot
	easer:         engine.Sequence_Easer,
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
		engine.filter_all_fills(),
		.Top_Bottom_Left_Right,
	)
	defer delete(chars[:])
	max_slot := 0
	for id in chars do max_slot = max(max_slot, int(id))
	s.final_colors = make([dynamic]engine.Color_Pair, max_slot + 1)
	s.scene_handles = make([dynamic]int, max_slot + 1)
	s.second_scenes = make([dynamic]int, max_slot + 1)
	for i in 0 ..= max_slot do s.scene_handles[i], s.second_scenes[i] = -1, -1

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
		sc1 := engine.new_scene(e, false, .None, {})
		for symbol in s.config.sweep_symbols {
			gray := gray_shades[rand.int_max(5)]
			engine.scene_add_frame(&e.scenes[sc1], symbol, 5, gray, nil, false)
		}
		engine.scene_add_frame(&e.scenes[sc1], sym, 1, gray_shades[1], nil, false)
		s.scene_handles[id] = sc1

		// second sweep: final gradient colors then the final frame
		sc2 := engine.new_scene(e, false, .None, {})
		for symbol in s.config.sweep_symbols {
			col := spectrum[rand.int_max(len(spectrum))]
			engine.scene_add_frame(&e.scenes[sc2], symbol, 5, col, nil, false)
		}
		engine.scene_add_frame(&e.scenes[sc2], sym, 1, s.final_colors[id].fg, nil, false)
		s.second_scenes[id] = sc2
	}

	s.easer.groups = engine.get_characters_grouped(
		engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas},
		engine.filter_all_fills(),
		s.config.first_sweep_direction,
	)
	s.easer.tracker = engine.Easing_Tracker {
		fn          = engine.ease_of(.Circular_In_Out),
		total_steps = 100,
	}
	s.second_groups = engine.get_characters_grouped(
		engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas},
		engine.filter_all_fills(),
		s.config.second_sweep_direction,
	)
	s.first_phase = true
}

sweep_next :: proc(s: ^Sweep_State, e: ^engine.Engine) -> bool {
	if len(e.active) == 0 && s.complete {
		return false
	}
	r := engine.seq_step(&s.easer)
	for gi in r.added_start ..< r.added_end {
		for id in engine.group_slice(s.easer.groups, gi) {
			if s.first_phase do e.chars.is_visible[id] = true
			handle := s.first_phase ? s.scene_handles[id] : s.second_scenes[id]
			engine.activate_scene(e, id, handle)
			engine.active_insert(e, id)
		}
	}
	if engine.seq_complete(s.easer) {
		if s.first_phase {
			engine.groups_delete(&s.easer.groups)
			s.easer.groups = s.second_groups
			engine.tracker_reset(&s.easer.tracker)
			s.first_phase = false
		} else {
			s.complete = true
		}
	}
	engine.update(e)
	engine.frame(e)
	return true
}
