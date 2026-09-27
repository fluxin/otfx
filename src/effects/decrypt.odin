package effects

import "../engine"
import "core:fmt"

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
Decrypt_Typing_Samples :: [9]int{0, 0, 1, 1, 2, 2, 3, 3, 4}
Decrypt_Fast_Frames :: 80
Decrypt_Slow_Max_Frames :: 15
Decrypt_Fast_Ticks :: Decrypt_Fast_Frames * 2
Decrypt_Discovered_Ticks :: 11 * 5 // ten interpolation steps plus exact final
Decrypt_Block_Symbols :: [4]rune{'▉', '▓', '▒', '░'}

// Per-character timeline columns. Symbol values are u16 indices into the
// shared encrypted alphabet; there are no scene/event objects in the hot path.
Decrypt_State :: struct {
	config:              Decrypt_Config,
	characters:          [dynamic]engine.Particle_Id,
	final_index:         [dynamic]int, // spectrum index by character slot
	fades:               engine.Gradient_Steps, // fades to each spectrum entry
	typing_start_ticks:  [dynamic]int,
	typing_previous:     [dynamic]int,
	typing_changes:      [dynamic]engine.Sample_Change,
	typing_tail:         int,
	fast_symbols:        [dynamic]u16, // n * 80
	slow_symbols:        [dynamic]u16, // n * 15
	slow_end_ticks:      [dynamic]int, // n * 15 cumulative ends
	slow_counts:         [dynamic]u8,
	slow_active:         [dynamic]int,
	slow_frame:          [dynamic]u8,
	slow_totals:         [dynamic]int,
	typing_head:         int,
	typing_tick:         int,
	typing_finish_tick:  int,
	decrypt_tick:        int,
	decrypt_finish_tick: int,
	phase:               Decrypt_Phase,
	encrypted_symbols:   [dynamic]rune,
	typing_glyphs:       [dynamic]rune,
	cipher_codes:        [dynamic]engine.Appearance_Id, // ciphertext appearance palette
	typing_codes:        [dynamic]engine.Appearance_Id, // n * Decrypt_Typing_Frames
	color_index:         [dynamic]int, // decrypt row -> ciphertext palette
	color_handling:      engine.Existing_Color_Handling,
}

encrypted_symbols_build :: proc() -> [dynamic]rune {
	symbols: [dynamic]rune
	for n in 33 ..< 127 do append(&symbols, rune(n))
	for n in 9608 ..< 9632 do append(&symbols, rune(n))
	for n in 9472 ..< 9599 do append(&symbols, rune(n))
	for n in 174 ..< 452 do append(&symbols, rune(n))
	return symbols
}

decrypt_build :: proc(s: ^Decrypt_State, e: ^engine.Engine) {
	encrypted_symbols := encrypted_symbols_build()
	s.encrypted_symbols = encrypted_symbols
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
	s.characters = engine.get_particles(
		engine.Particle_Query {
			e.particle_sets,
			e.particles.initial_coord[:len(e.particles)],
			e.canvas,
		},
		engine.PARTICLE_FILTER_INPUT,
		.Top_Bottom_Left_Right,
	)
	n := len(s.characters)
	s.color_handling = e.cfg.existing_color_handling
	s.final_index = make([dynamic]int, n)
	s.fades = engine.gradient_steps_make(e, engine.Color{0xff, 0xff, 0xff}, spectrum[:], 10)
	s.typing_start_ticks = make([dynamic]int, n)
	s.typing_previous = make([dynamic]int, n)
	s.typing_changes = make([dynamic]engine.Sample_Change, n)
	typing_symbols := make([dynamic]u16, n)
	defer delete(typing_symbols)
	// Typing frames reuse the ciphertext palette's prepared appearances.
	palette := max(len(s.config.ciphertext_colors), 1)
	s.cipher_codes = make([dynamic]engine.Appearance_Id, palette)
	for color, ci in s.config.ciphertext_colors {
		s.cipher_codes[ci] = engine.prepare_appearance(e, engine.Appearance{colors = {fg = color}})
	}
	s.typing_codes = make([dynamic]engine.Appearance_Id, n * Decrypt_Typing_Frames)
	s.color_index = make([dynamic]int, n)
	s.fast_symbols = make([dynamic]u16, n * Decrypt_Fast_Frames)
	s.slow_symbols = make([dynamic]u16, n * Decrypt_Slow_Max_Frames)
	s.slow_end_ticks = make([dynamic]int, n * Decrypt_Slow_Max_Frames)
	s.slow_counts = make([dynamic]u8, n)
	s.slow_active = make([dynamic]int, n)
	for &slot, i in s.slow_active do slot = i
	s.slow_frame = make([dynamic]u8, n)
	s.slow_totals = make([dynamic]int, n)

	// Preserve source RNG ordering: make all typing rows, then all decrypt rows.
	for id, i in s.characters {
		s.final_index[i] = engine.gradient_sample_index(
			sampler,
			len(spectrum),
			e.particles.initial_coord[id],
		)
		s.typing_start_ticks[i] = -1
		s.typing_previous[i] = -1
		base := i * Decrypt_Typing_Frames
		for frame in 0 ..< Decrypt_Typing_Frames - 1 {
			s.typing_codes[base + frame] = s.cipher_codes[engine.random_below(len(s.config.ciphertext_colors))]
		}
		typing_symbols[i] = u16(engine.random_below(len(encrypted_symbols)))
		s.typing_codes[base + Decrypt_Typing_Frames - 1] =
			s.cipher_codes[engine.random_below(len(s.config.ciphertext_colors))]
	}
	for _, i in s.characters {
		s.color_index[i] = engine.random_below(len(s.config.ciphertext_colors))
		fast_base := i * Decrypt_Fast_Frames
		for frame in 0 ..< Decrypt_Fast_Frames do s.fast_symbols[fast_base + frame] = u16(engine.random_below(len(encrypted_symbols)))
		slow_base := i * Decrypt_Slow_Max_Frames
		slow_count := engine.random_range(1, Decrypt_Slow_Max_Frames + 1)
		s.slow_counts[i] = u8(slow_count)
		total := 0
		for frame in 0 ..< slow_count {
			s.slow_symbols[slow_base + frame] = u16(engine.random_below(len(encrypted_symbols)))
			duration := engine.random_range(3, 6)
			if engine.random_range(0, 101) <= 30 do duration = engine.random_range(35, 60)
			total += duration
			s.slow_end_ticks[slow_base + frame] = total
		}
		s.slow_totals[i] = total
		s.decrypt_finish_tick = max(
			s.decrypt_finish_tick,
			Decrypt_Fast_Ticks + total + Decrypt_Discovered_Ticks,
		)
	}

	s.typing_glyphs = make([dynamic]rune, n * Decrypt_Typing_Frames)
	blocks := Decrypt_Block_Symbols
	for i in 0 ..< n {
		for frame in 0 ..< Decrypt_Typing_Frames {
			symbol :=
				frame < Decrypt_Typing_Frames - 1 ? blocks[frame] : encrypted_symbols[int(typing_symbols[i])]
			s.typing_glyphs[i * Decrypt_Typing_Frames + frame] = symbol
		}
	}
}

decrypt_next :: proc(s: ^Decrypt_State, e: ^engine.Engine) -> bool #no_bounds_check {
	if s.phase == .Typing {
		if s.typing_head == len(s.characters) && s.typing_tick >= s.typing_finish_tick {
			s.phase = .Decrypting
		} else {
			if s.typing_head < len(s.characters) && engine.random_range(0, 101) <= 75 {
				for _ in 0 ..< s.config.typing_speed {
					if s.typing_head == len(s.characters) do break
					i := s.typing_head
					s.typing_head += 1
					s.typing_start_ticks[i] = s.typing_tick
					s.typing_finish_tick = max(s.typing_finish_tick, s.typing_tick + 9)
					engine.set_particle(e, s.characters[i], engine.Visible(true))
				}
			}
			samples := Decrypt_Typing_Samples
			changes := engine.sample_timeline_changes(
				s.typing_changes[:],
				s.typing_start_ticks[s.typing_tail:s.typing_head],
				s.typing_previous[s.typing_tail:s.typing_head],
				s.typing_tick,
				samples[:],
			)
			for change in changes {
				i := s.typing_tail + change.slot
				id, frame := s.characters[i], change.sample
				engine.set_symbol(e, id, s.typing_glyphs[i * Decrypt_Typing_Frames + frame])
				engine.set_appearance(e, id, s.typing_codes[i * Decrypt_Typing_Frames + frame])
			}
			// Activations are ordered, so completed appearance writers form a prefix.
			// The existing finish tick still supplies the final one-tick hold.
			for s.typing_tail < s.typing_head &&
			    s.typing_previous[s.typing_tail] == Decrypt_Typing_Frames - 1 {
				s.typing_tail += 1
			}
			s.typing_tick += 1
			return true
		}
	}
	if s.phase == .Decrypting {
		if s.decrypt_tick == s.decrypt_finish_tick do return false
		if s.decrypt_tick < Decrypt_Fast_Ticks {
			if s.decrypt_tick % 2 != 0 {
				s.decrypt_tick += 1
				return true
			}
			frame := s.decrypt_tick / 2
			for base := 0; base < len(s.characters); base += 8 {
				count := min(8, len(s.characters) - base)
				codes: [8]engine.Appearance_Id
				for lane in 0 ..< count {
					i := base + lane
					symbol := int(s.fast_symbols[i * Decrypt_Fast_Frames + frame])
					engine.set_symbol(e, s.characters[i], s.encrypted_symbols[symbol])
					if s.decrypt_tick == 0 do codes[lane] = s.cipher_codes[s.color_index[i]]
				}
				// Cipher appearance is shared by the entire fast/slow phase.
				if s.decrypt_tick == 0 do engine.set_appearances(e, s.characters[base:base + count], codes[:count])
			}
			s.decrypt_tick += 1
			return true
		}
		slow_tick := s.decrypt_tick - Decrypt_Fast_Ticks
		write := 0
		for i in s.slow_active {
			id := s.characters[i]
			base := i * Decrypt_Slow_Max_Frames
			frame := int(s.slow_frame[i])
			changed := slow_tick == 0
			if frame < int(s.slow_counts[i]) && slow_tick >= s.slow_end_ticks[base + frame] {
				frame += 1
				s.slow_frame[i] = u8(frame)
				changed = true
			}
			if frame < int(s.slow_counts[i]) {
				if changed {
					symbol := int(s.slow_symbols[base + frame])
					engine.set_symbol(e, id, s.encrypted_symbols[symbol])
				}
				s.slow_active[write] = i
				write += 1
				continue
			}
			discovered_tick := slow_tick - s.slow_totals[i]
			if discovered_tick % 5 != 0 {
				s.slow_active[write] = i
				write += 1
				continue
			}
			step := min(discovered_tick / 5, 10)
			if discovered_tick == 0 do engine.set_symbol(e, id, e.particles.initial_symbol[id])
			if s.color_handling == .Dynamic {
				appearance := engine.Appearance{}
				engine.dynamic_gradient_to_input(
					&appearance,
					engine.Color{0xff, 0xff, 0xff},
					engine.get_initial_appearance(e, engine.Particle_Id(id)),
					10,
					step,
				)
				engine.set_appearance(e, id, appearance)
			} else {
				// Step 10 is the exact final color, also held after discovery.
				engine.set_appearance(e, id, engine.gradient_step(s.fades, s.final_index[i], step))
			}
			if discovered_tick < Decrypt_Discovered_Ticks {
				s.slow_active[write] = i
				write += 1
			}
		}
		resize(&s.slow_active, write)
		s.decrypt_tick += 1
		return true
	}
	return false
}
