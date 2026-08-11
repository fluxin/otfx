package effects

import engine "../engine"
import rand "core:math/rand"

import "core:fmt"

// decrypt — a typing phase resolves into per-character decryption, then the
// true symbols are discovered.

Decrypt_Config :: struct {
	typing_speed:             int,
	ciphertext_colors:        [dynamic]engine.Color,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

decrypt_config_default :: proc() -> Decrypt_Config {
	cfg := Decrypt_Config {
		typing_speed             = 2,
		final_gradient_direction = .Vertical,
	}
	append(
		&cfg.ciphertext_colors,
		..[]engine.Color {
			engine.Color{0x00, 0x80, 0x00},
			engine.Color{0x00, 0xcb, 0x00},
			engine.Color{0x00, 0xff, 0x00},
		},
	)
	append(&cfg.final_gradient_stops, engine.Color{0xed, 0xa0, 0x00})
	append(&cfg.final_gradient_steps, 12)
	return cfg
}

decrypt_parse :: proc(cfg: ^Decrypt_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--typing-speed":
			if !parse_int_flag(&cfg.typing_speed, args, &i, value, has_value) do return false
		case "--ciphertext-colors":
			if !parse_colors_flag(&cfg.ciphertext_colors, args, &i, value, has_value) do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown decrypt option: ", name)
			return false
		}
	}
	return true
}

Decrypt_Phase :: enum {
	Typing,
	Decrypting,
}

Decrypt_State :: struct {
	config:             Decrypt_Config,
	final_colors:       [dynamic]engine.Color_Pair,
	typing_scenes:      [dynamic]int,
	fast_scenes:        [dynamic]int,
	typing_pending:     [dynamic]engine.Char_Id,
	typing_head:        int,
	decrypting_pending: [dynamic]engine.Char_Id,
	phase:              Decrypt_Phase,
	encrypted_symbols:  [dynamic]string,
}

encrypted_symbols_build :: proc() -> [dynamic]string {
	symbols: [dynamic]string
	for n in 33 ..< 127 {
		append(&symbols, engine.rune_to_string(rune(n)))
	}
	for n in 9608 ..< 9632 {
		append(&symbols, engine.rune_to_string(rune(n)))
	}
	for n in 9472 ..< 9599 {
		append(&symbols, engine.rune_to_string(rune(n)))
	}
	for n in 174 ..< 452 {
		append(&symbols, engine.rune_to_string(rune(n)))
	}
	return symbols
}

decrypt_build :: proc(s: ^Decrypt_State, e: ^engine.Engine) {
	s.encrypted_symbols = encrypted_symbols_build()

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

	chars := engine.get_characters(
		engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas},
		engine.filter_input(),
		.Top_Bottom_Left_Right,
	)
	defer delete(chars[:])
	max_slot := 0
	for id in chars do max_slot = max(max_slot, int(id))
	s.final_colors = make([dynamic]engine.Color_Pair, max_slot + 1)
	s.typing_scenes = make([dynamic]int, max_slot + 1)
	s.fast_scenes = make([dynamic]int, max_slot + 1)
	for i in 0 ..= max_slot do s.typing_scenes[i], s.fast_scenes[i] = -1, -1

	// typing scenes: block chars then a cipher symbol
	for id in chars {
		c := e.chars.input_coord[id]
		s.final_colors[id] = engine.Color_Pair {
			fg = engine.gradient_sample(final_sampler, final_spectrum[:], c),
			bg = nil,
		}

		typing := engine.new_scene(e, false, .None, {})
		block_chars := []string{"▉", "▓", "▒", "░"}
		for block in block_chars {
			col := s.config.ciphertext_colors[rand.int_max(len(s.config.ciphertext_colors))]
			engine.scene_add_frame(&e.scenes[typing], block, 2, col, nil, false)
		}
		sym := s.encrypted_symbols[rand.int_max(len(s.encrypted_symbols))]
		col := s.config.ciphertext_colors[rand.int_max(len(s.config.ciphertext_colors))]
		engine.scene_add_frame(&e.scenes[typing], sym, 1, col, nil, false)
		s.typing_scenes[id] = typing
		append(&s.typing_pending, id)
	}

	// decryption scenes: fast -> slow -> discovered
	for id in chars {
		sym := e.chars.input_symbol[id]
		col := s.config.ciphertext_colors[rand.int_max(len(s.config.ciphertext_colors))]

		fast := engine.new_scene(e, false, .None, {})
		for _ in 0 ..< 80 {
			sym2 := s.encrypted_symbols[rand.int_max(len(s.encrypted_symbols))]
			engine.scene_add_frame(&e.scenes[fast], sym2, 2, col, nil, false)
		}
		s.fast_scenes[id] = fast

		slow := engine.new_scene(e, false, .None, {})
		for _ in 0 ..< rand.int_range(1, 16) {
			sym2 := s.encrypted_symbols[rand.int_max(len(s.encrypted_symbols))]
			duration := rand.int_range(3, 6)
			if rand.int_range(0, 101) <= 30 do duration = rand.int_range(35, 60)
			engine.scene_add_frame(&e.scenes[slow], sym2, duration, col, nil, false)
		}

		discovered := engine.new_scene(e, false, .None, {})
		final := s.final_colors[id].fg.?
		g := engine.gradient_with_steps(
			[]engine.Color{engine.Color{0xff, 0xff, 0xff}, final},
			10,
			false,
		)
		defer delete(g[:])
		engine.scene_add_gradient(&e.scenes[discovered], []string{sym}, 5, g[:], nil)

		engine.register_event(
			e,
			id,
			.Scene_Complete,
			.Scene,
			fast,
			{kind = .Activate_Scene, scene = slow},
		)
		engine.register_event(
			e,
			id,
			.Scene_Complete,
			.Scene,
			slow,
			{kind = .Activate_Scene, scene = discovered},
		)
		append(&s.decrypting_pending, id)
	}
}

decrypt_next :: proc(s: ^Decrypt_State, e: ^engine.Engine) -> bool {
	if s.phase == .Typing {
		if s.typing_head == len(s.typing_pending) && len(e.active) == 0 {
			// switch to decryption: activate fast_decrypt on all, in id order
			engine.active_clear(e)
			for id in s.decrypting_pending {
				engine.active_insert(e, id)
			}
			for id in s.decrypting_pending {
				engine.activate_scene(e, id, s.fast_scenes[id])
			}
			s.phase = .Decrypting
		} else {
			if s.typing_head < len(s.typing_pending) && rand.int_range(0, 101) <= 75 {
				for _ in 0 ..< s.config.typing_speed {
					if s.typing_head == len(s.typing_pending) do break
					next := s.typing_pending[s.typing_head]
					s.typing_head += 1
					e.chars.is_visible[next] = true
					engine.activate_scene(e, next, s.typing_scenes[next])
					engine.active_insert(e, next)
				}
			}
			engine.update(e)
			engine.frame(e)
			return true
		}
	}
	if s.phase == .Decrypting {
		if len(e.active) == 0 do return false
		engine.update(e)
		engine.frame(e)
		return true
	}
	return false
}
