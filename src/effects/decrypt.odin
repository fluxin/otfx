package effects

import "../engine"
import "core:fmt"
import "core:math/rand"

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
		..[]engine.Color{{0x00, 0x80, 0x00}, {0x00, 0xcb, 0x00}, {0x00, 0xff, 0x00}},
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
Decrypt_Typing_Frames :: 5
Decrypt_Fast_Frames :: 80
Decrypt_Slow_Max_Frames :: 15
Decrypt_Fast_Ticks :: Decrypt_Fast_Frames * 2
Decrypt_Discovered_Ticks :: 11 * 5 // ten interpolation steps plus exact final
Decrypt_Block_Symbols :: [4]string{"▉", "▓", "▒", "░"}

// Per-character timeline columns. Symbol values are u16 indices into the
// shared encrypted alphabet; there are no scene/event objects in the hot path.
Decrypt_State :: struct {
	config:              Decrypt_Config,
	characters:          [dynamic]engine.Char_Id,
	final_colors:        [dynamic]engine.Color,
	typing_start_ticks:  [dynamic]int,
	typing_colors:       [dynamic]engine.Color, // n * 5
	typing_symbols:      [dynamic]u16,
	decrypt_colors:      [dynamic]engine.Color,
	fast_symbols:        [dynamic]u16, // n * 80
	slow_symbols:        [dynamic]u16, // n * 15
	slow_end_ticks:      [dynamic]int, // n * 15 cumulative ends
	slow_counts:         [dynamic]u8,
	slow_frame:          [dynamic]u8,
	slow_totals:         [dynamic]int,
	typing_head:         int,
	typing_tick:         int,
	typing_finish_tick:  int,
	decrypt_tick:        int,
	decrypt_finish_tick: int,
	phase:               Decrypt_Phase,
	encrypted_symbols:   [dynamic]string,
}

encrypted_symbols_build :: proc() -> [dynamic]string {
	symbols: [dynamic]string
	for n in 33 ..< 127 do append(&symbols, engine.rune_to_string(rune(n)))
	for n in 9608 ..< 9632 do append(&symbols, engine.rune_to_string(rune(n)))
	for n in 9472 ..< 9599 do append(&symbols, engine.rune_to_string(rune(n)))
	for n in 174 ..< 452 do append(&symbols, engine.rune_to_string(rune(n)))
	return symbols
}

decrypt_build :: proc(s: ^Decrypt_State, e: ^engine.Engine) {
	s.encrypted_symbols = encrypted_symbols_build()
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
	n := len(s.characters)
	s.final_colors = make([dynamic]engine.Color, n)
	s.typing_start_ticks = make([dynamic]int, n)
	s.typing_colors = make([dynamic]engine.Color, n * Decrypt_Typing_Frames)
	s.typing_symbols = make([dynamic]u16, n)
	s.decrypt_colors = make([dynamic]engine.Color, n)
	s.fast_symbols = make([dynamic]u16, n * Decrypt_Fast_Frames)
	s.slow_symbols = make([dynamic]u16, n * Decrypt_Slow_Max_Frames)
	s.slow_end_ticks = make([dynamic]int, n * Decrypt_Slow_Max_Frames)
	s.slow_counts = make([dynamic]u8, n)
	s.slow_frame = make([dynamic]u8, n)
	s.slow_totals = make([dynamic]int, n)

	// Preserve source RNG ordering: make all typing rows, then all decrypt rows.
	for id, i in s.characters {
		s.final_colors[i] = engine.gradient_sample(sampler, spectrum[:], e.chars.input_coord[id])
		s.typing_start_ticks[i] = -1
		base := i * Decrypt_Typing_Frames
		for frame in 0 ..< Decrypt_Typing_Frames - 1 do s.typing_colors[base + frame] = s.config.ciphertext_colors[rand.int_max(len(s.config.ciphertext_colors))]
		s.typing_symbols[i] = u16(rand.int_max(len(s.encrypted_symbols)))
		s.typing_colors[base + Decrypt_Typing_Frames - 1] =
			s.config.ciphertext_colors[rand.int_max(len(s.config.ciphertext_colors))]
	}
	for _, i in s.characters {
		s.decrypt_colors[i] =
			s.config.ciphertext_colors[rand.int_max(len(s.config.ciphertext_colors))]
		fast_base := i * Decrypt_Fast_Frames
		for frame in 0 ..< Decrypt_Fast_Frames do s.fast_symbols[fast_base + frame] = u16(rand.int_max(len(s.encrypted_symbols)))
		slow_base := i * Decrypt_Slow_Max_Frames
		slow_count := rand.int_range(1, Decrypt_Slow_Max_Frames + 1)
		s.slow_counts[i] = u8(slow_count)
		total := 0
		for frame in 0 ..< slow_count {
			s.slow_symbols[slow_base + frame] = u16(rand.int_max(len(s.encrypted_symbols)))
			duration := rand.int_range(3, 6)
			if rand.int_range(0, 101) <= 30 do duration = rand.int_range(35, 60)
			total += duration
			s.slow_end_ticks[slow_base + frame] = total
		}
		s.slow_totals[i] = total
		s.decrypt_finish_tick = max(
			s.decrypt_finish_tick,
			Decrypt_Fast_Ticks + total + Decrypt_Discovered_Ticks,
		)
	}
}

decrypt_next :: proc(s: ^Decrypt_State, e: ^engine.Engine) -> ([]engine.Char_Id, bool) {
	if s.phase == .Typing {
		if s.typing_head == len(s.characters) && s.typing_tick >= s.typing_finish_tick {
			s.phase = .Decrypting
		} else {
			if s.typing_head < len(s.characters) && rand.int_range(0, 101) <= 75 {
				for _ in 0 ..< s.config.typing_speed {
					if s.typing_head == len(s.characters) do break
					i := s.typing_head
					s.typing_head += 1
					s.typing_start_ticks[i] = s.typing_tick
					s.typing_finish_tick = max(s.typing_finish_tick, s.typing_tick + 9)
					e.chars.is_visible[s.characters[i]] = true
				}
			}
			blocks := Decrypt_Block_Symbols
			for id, i in s.characters {
				start := s.typing_start_ticks[i]
				if start < 0 do continue
				frame := min((s.typing_tick - start) / 2, Decrypt_Typing_Frames - 1)
				e.chars.visual[id].symbol =
					frame < Decrypt_Typing_Frames - 1 ? blocks[frame] : s.encrypted_symbols[int(s.typing_symbols[i])]
				e.chars.visual[id].fg = s.typing_colors[i * Decrypt_Typing_Frames + frame]
			}
			s.typing_tick += 1
			return s.characters[:], true
		}
	}
	if s.phase == .Decrypting {
		if s.decrypt_tick == s.decrypt_finish_tick do return nil, false
		for id, i in s.characters {
			if s.decrypt_tick < Decrypt_Fast_Ticks {
				e.chars.visual[id].symbol =
					s.encrypted_symbols[int(s.fast_symbols[i * Decrypt_Fast_Frames + s.decrypt_tick / 2])]
				e.chars.visual[id].fg = s.decrypt_colors[i]
				continue
			}
			slow_tick := s.decrypt_tick - Decrypt_Fast_Ticks
			frame := int(s.slow_frame[i])
			if frame < int(s.slow_counts[i]) &&
			   slow_tick >= s.slow_end_ticks[i * Decrypt_Slow_Max_Frames + frame] {
				frame += 1
				s.slow_frame[i] = u8(frame)
			}
			if frame < int(s.slow_counts[i]) {
				e.chars.visual[id].symbol =
					s.encrypted_symbols[int(s.slow_symbols[i * Decrypt_Slow_Max_Frames + frame])]
				e.chars.visual[id].fg = s.decrypt_colors[i]
				continue
			}
			discovered_tick := slow_tick - s.slow_totals[i]
			e.chars.visual[id].symbol = e.chars.input_symbol[id]
			e.chars.visual[id].fg =
				discovered_tick < Decrypt_Discovered_Ticks ? engine.gradient_between_step(engine.Color{0xff, 0xff, 0xff}, s.final_colors[i], 10, min(discovered_tick / 5, 10)) : s.final_colors[i]
		}
		s.decrypt_tick += 1
		return s.characters[:], true
	}
	return nil, false
}
