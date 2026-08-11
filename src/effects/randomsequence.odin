package effects

import "../engine"
import "core:math/rand"

import "core:fmt"

// randomsequence — characters reveal at random positions in a blur-to-focus
// gradient.

Randomsequence_Config :: struct {
	speed:                    f64,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_frames:    int,
	final_gradient_direction: engine.Gradient_Direction,
}

randomsequence_config_default :: proc() -> Randomsequence_Config {
	cfg := Randomsequence_Config {
		speed                    = 0.007,
		final_gradient_frames    = 8,
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

randomsequence_parse :: proc(cfg: ^Randomsequence_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--speed":
			if !parse_float_flag(&cfg.speed, args, &i, value, has_value) do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-frames":
			if !parse_int_flag(&cfg.final_gradient_frames, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown randomsequence option: ", name)
			return false
		}
	}
	return true
}

Randomsequence_State :: struct {
	config:         Randomsequence_Config,
	characters:     [dynamic]engine.Char_Id,
	index_by_id:    [dynamic]int,
	palette:        [dynamic]engine.Color,
	start_ticks:    [dynamic]int,
	active_slots:   [dynamic]int,
	palette_len:    int,
	pending:        [dynamic]engine.Char_Id,
	chars_per_tick: int,
	color_handling: engine.Existing_Color_Handling,
	tick:           int,
}

randomsequence_build :: proc(s: ^Randomsequence_State, e: ^engine.Engine) {
	s.chars_per_tick = max(int(s.config.speed * f64(len(e.character_sets.input))), 1)
	s.color_handling = e.cfg.existing_color_handling

	chars := engine.get_characters(
		engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas},
		engine.CHAR_FILTER_INPUT,
		.Top_Bottom_Left_Right,
	)
	s.characters = chars
	s.index_by_id = make([dynamic]int, len(e.chars))
	s.start_ticks = make([dynamic]int, len(chars))
	for i in 0 ..< len(s.start_ticks) do s.start_ticks[i] = -1

	if s.color_handling != .Dynamic {
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
		bg := e.cfg.terminal_background_color
		for id, slot in chars {
			final := engine.gradient_sample(sampler, spectrum[:], e.chars.input_coord[id])
			g := engine.gradient_make([]engine.Color{bg, final}, []int{7}, false)
			if slot == 0 do s.palette_len = len(g)
			append(&s.palette, ..g[:])
			delete(g[:])
		}
	}

	for id, slot in chars {
		s.index_by_id[id] = slot
		e.chars.is_visible[id] = false
		append(&s.pending, id)
	}
	rand.shuffle(s.pending[:])
}

randomsequence_next :: proc(
	s: ^Randomsequence_State,
	e: ^engine.Engine,
) -> (
	[]engine.Char_Id,
	bool,
) {
	if len(s.pending) == 0 && len(s.active_slots) == 0 {
		return nil, false
	}
	for _ in 0 ..< s.chars_per_tick {
		if len(s.pending) == 0 do break
		next := pop(&s.pending)
		e.chars.is_visible[next] = true
		slot := s.index_by_id[next]
		s.start_ticks[slot] = s.tick
		append(&s.active_slots, slot)
		e.chars.visual[next].symbol = e.chars.input_symbol[next]
	}
	write := 0
	for slot in s.active_slots {
		age := s.tick - s.start_ticks[slot]
		id := s.characters[slot]
		life := s.palette_len * s.config.final_gradient_frames
		if s.color_handling == .Dynamic {
			style := e.chars.input_style[id]
			if style.fg != nil || style.bg != nil {
				step := min(age / s.config.final_gradient_frames, 7)
				engine.dynamic_gradient_to_input(
					&e.chars.visual[id],
					e.cfg.terminal_background_color,
					style,
					7,
					step,
				)
				life = 8 * s.config.final_gradient_frames
			} else {
				if age < 8 * s.config.final_gradient_frames {
					e.chars.visual[id].fg = engine.gradient_between_step(
						e.cfg.terminal_background_color,
						engine.Color{0x80, 0x80, 0x80},
						7,
						age / s.config.final_gradient_frames,
					)
					e.chars.visual[id].bg = nil
				} else {
					e.chars.visual[id].fg = nil
					e.chars.visual[id].bg = nil
				}
				life = 9 * s.config.final_gradient_frames
			}
		} else {
			e.chars.visual[id].fg =
				s.palette[slot * s.palette_len + age / s.config.final_gradient_frames]
		}
		if age + 1 < life {
			s.active_slots[write] = slot
			write += 1
		}
	}
	resize(&s.active_slots, write)
	s.tick += 1
	return nil, true
}
