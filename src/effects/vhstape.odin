package effects

import engine "../engine"

import "core:fmt"
import rand "core:math/rand"

Vhs_Noise_Symbols :: [4]string{"#", "*", ".", ":"}

Vhstape_Config :: struct {
	glitch_line_colors:       [dynamic]engine.Color,
	glitch_wave_colors:       [dynamic]engine.Color,
	noise_colors:             [dynamic]engine.Color,
	glitch_line_chance:       f64,
	noise_chance:             f64,
	total_glitch_time:        int,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

vhstape_config_default :: proc() -> Vhstape_Config {
	cfg := Vhstape_Config {
		glitch_line_chance       = 0.05,
		noise_chance             = 0.004,
		total_glitch_time        = 600,
		final_gradient_direction = .Vertical,
	}
	append(
		&cfg.glitch_line_colors,
		..[]engine.Color {
			engine.Color{0xFF, 0xFF, 0xFF},
			engine.Color{0xFF, 0x00, 0x00},
			engine.Color{0x00, 0xFF, 0x00},
			engine.Color{0x00, 0x00, 0xFF},
			engine.Color{0xFF, 0xFF, 0xFF},
		},
	)
	append(&cfg.glitch_wave_colors, ..cfg.glitch_line_colors[:])
	append(
		&cfg.noise_colors,
		..[]engine.Color {
			engine.Color{0x1E, 0x1E, 0x1F},
			engine.Color{0x3C, 0x3B, 0x3D},
			engine.Color{0x6D, 0x6C, 0x70},
			engine.Color{0xA2, 0xA1, 0xA6},
			engine.Color{0xCB, 0xC9, 0xCF},
			engine.Color{0xFF, 0xFF, 0xFF},
		},
	)
	append(
		&cfg.final_gradient_stops,
		..[]engine.Color {
			engine.Color{0xAB, 0x48, 0xFF},
			engine.Color{0xE7, 0xB2, 0xB2},
			engine.Color{0xFF, 0xFE, 0xBD},
		},
	)
	append(&cfg.final_gradient_steps, 12)
	return cfg
}

vhstape_parse :: proc(cfg: ^Vhstape_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--glitch-line-colors":
			if !parse_colors_flag(&cfg.glitch_line_colors, args, &i, value, has_value) do return false
		case "--glitch-wave-colors":
			if !parse_colors_flag(&cfg.glitch_wave_colors, args, &i, value, has_value) do return false
		case "--noise-colors":
			if !parse_colors_flag(&cfg.noise_colors, args, &i, value, has_value) do return false
		case "--glitch-line-chance":
			if !parse_float_flag(&cfg.glitch_line_chance, args, &i, value, has_value) || cfg.glitch_line_chance < 0 || cfg.glitch_line_chance > 1 do return false
		case "--noise-chance":
			if !parse_float_flag(&cfg.noise_chance, args, &i, value, has_value) || cfg.noise_chance < 0 || cfg.noise_chance > 1 do return false
		case "--total-glitch-time":
			if !parse_int_flag(&cfg.total_glitch_time, args, &i, value, has_value) || cfg.total_glitch_time <= 0 do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown vhstape option: ", name)
			return false
		}
	}
	return true
}

Vhstape_Phase :: enum {
	Glitching,
	Noise,
	Redraw,
}

// The row state is parallel to `rows.offsets`; a kind value of one identifies
// a moving three-row wave, zero an isolated line glitch.
Vhstape_State :: struct {
	config:        Vhstape_Config,
	characters:    [dynamic]engine.Char_Id,
	final_colors:  [dynamic]engine.Color,
	rows:          engine.Char_Groups,
	row_starts:    [dynamic]int,
	row_durations: [dynamic]int,
	row_offsets:   [dynamic]int,
	row_kinds:     [dynamic]u8,
	phase:         Vhstape_Phase,
	tick:          int,
	phase_tick:    int,
	wave_cooldown: int,
	noise_index:   int,
	redraw_row:    int,
}

vhstape_build :: proc(s: ^Vhstape_State, e: ^engine.Engine) {
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
	query := engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas}
	s.characters = engine.get_characters(query, engine.filter_input(), .Top_Bottom_Left_Right)
	// Char_Id is the Character_Storage index, so this is a direct color column.
	s.final_colors = make([dynamic]engine.Color, len(e.chars))
	input_coords := e.chars.input_coord
	visual_fg := e.chars.visual_fg
	visible := e.chars.is_visible
	for id in s.characters {
		s.final_colors[id] = engine.gradient_sample(sampler, spectrum[:], input_coords[id])
		visual_fg[id] = s.final_colors[id]
		visible[id] = true
	}
	s.rows = engine.get_characters_grouped(query, engine.filter_input(), .Row_B2T)
	row_count := engine.group_count(s.rows)
	s.row_starts = make([dynamic]int, row_count)
	s.row_durations = make([dynamic]int, row_count)
	s.row_offsets = make([dynamic]int, row_count)
	s.row_kinds = make([dynamic]u8, row_count)
	for i in 0 ..< row_count do s.row_starts[i] = -1
}

vhstape_start_row :: proc(s: ^Vhstape_State, row: int, wave: bool) {
	if s.row_starts[row] >= 0 do return
	s.row_starts[row] = s.tick
	s.row_offsets[row] = rand.int_range(4, 26)
	if rand.int_max(2) == 0 do s.row_offsets[row] = -s.row_offsets[row]
	s.row_durations[row] = 2 * max(abs(s.row_offsets[row]) / 2, 1) + rand.int_range(20, 76)
	s.row_kinds[row] = wave ? 1 : 0
}

// The reference wave is not a random three-line glitch: its leading and
// trailing rows move eight columns and the centre row moves fourteen. Keep
// that fixed 8/14/8 profile as row columns, so the characteristic VHS bounce
// survives without per-character paths.
vhstape_start_wave_row :: proc(s: ^Vhstape_State, row, offset: int) {
	if s.row_starts[row] >= 0 do return
	s.row_starts[row] = s.tick
	s.row_offsets[row] = offset
	move_steps := max(engine.round_half_even(f64(offset) / 2), 1)
	// The reference has no hold on the wave paths; a short return gives the
	// next wave position a crisp, discrete handoff instead of a long glide.
	s.row_durations[row] = move_steps * 2
	s.row_kinds[row] = 1
}

vhstape_restore_row :: proc(s: ^Vhstape_State, e: ^engine.Engine, row: int) {
	input_coords := e.chars.input_coord
	current_coords := e.chars.current_coord
	visual_symbols := e.chars.visual_symbol
	input_symbols := e.chars.input_symbol
	visual_fg := e.chars.visual_fg
	for id in engine.group_slice(s.rows, row) {
		current_coords[id] = input_coords[id]
		visual_symbols[id] = input_symbols[id]
		visual_fg[id] = s.final_colors[id]
	}
	s.row_starts[row] = -1
}

vhstape_next :: proc(s: ^Vhstape_State, e: ^engine.Engine) -> bool {
	if s.phase == .Glitching {
		row_count := engine.group_count(s.rows)
		if s.wave_cooldown == 0 && row_count >= 3 {
			start := rand.int_range(max(row_count / 2 - 2, 0), row_count - 2)
			vhstape_start_wave_row(s, start, 8)
			vhstape_start_wave_row(s, start + 1, 14)
			vhstape_start_wave_row(s, start + 2, 8)
			// The path itself lasts 14 ticks. Re-arm soon after it returns so the
			// screen keeps shaking like tape tracking, rather than once per 40.
			s.wave_cooldown = 16
		} else {
			s.wave_cooldown -= 1
		}
		if rand.float64() < s.config.glitch_line_chance {
			vhstape_start_row(s, rand.int_max(row_count), false)
		}

		current_coords := e.chars.current_coord
		input_coords := e.chars.input_coord
		input_symbols := e.chars.input_symbol
		visual_symbols := e.chars.visual_symbol
		visual_fg := e.chars.visual_fg
		for row in 0 ..< row_count {
			start := s.row_starts[row]
			if start < 0 do continue
			age := s.tick - start
			if age >= s.row_durations[row] {
				vhstape_restore_row(s, e, row)
				continue
			}
			move_steps := max(abs(s.row_offsets[row]) / 2, 1)
			delta: int
			if age < move_steps {
				delta = s.row_offsets[row] * (age + 1) / move_steps
			} else if age < s.row_durations[row] - move_steps {
				delta = s.row_offsets[row]
			} else {
				remaining := s.row_durations[row] - age
				delta = s.row_offsets[row] * remaining / move_steps
			}
			palette :=
				s.row_kinds[row] == 0 ? s.config.glitch_line_colors[:] : s.config.glitch_wave_colors[:]
			color := palette[min(age / 4, len(palette) - 1)]
			for id in engine.group_slice(s.rows, row) {
				p := input_coords[id]
				current_coords[id] = engine.coord(p.column + delta, p.row)
				visual_symbols[id] = input_symbols[id]
				visual_fg[id] = color
			}
		}

		if rand.float64() < s.config.noise_chance {
			noise_symbols := Vhs_Noise_Symbols
			for id in s.characters {
				visual_symbols[id] = noise_symbols[rand.int_max(len(noise_symbols))]
				visual_fg[id] = s.config.noise_colors[rand.int_max(len(s.config.noise_colors))]
			}
		}
		s.tick += 1
		if s.tick == s.config.total_glitch_time {
			for row in 0 ..< row_count {
				if s.row_starts[row] >= 0 do vhstape_restore_row(s, e, row)
			}
			s.phase = .Noise
			s.phase_tick = 0
		}
		engine.frame(e, s.characters[:])
		return true
	}

	if s.phase == .Noise {
		if s.phase_tick == 30 {
			s.phase = .Redraw
			s.redraw_row = 0
			return vhstape_next(s, e)
		}
		noise_symbols := Vhs_Noise_Symbols
		visual_symbols := e.chars.visual_symbol
		visual_fg := e.chars.visual_fg
		for id in s.characters {
			visual_symbols[id] = noise_symbols[s.noise_index]
			visual_fg[id] = s.config.noise_colors[s.noise_index]
			s.noise_index += 1
			if s.noise_index == min(len(noise_symbols), len(s.config.noise_colors)) do s.noise_index = 0
		}
		s.phase_tick += 1
		engine.frame(e, s.characters[:])
		return true
	}

	if s.redraw_row == engine.group_count(s.rows) do return false
	input_coords := e.chars.input_coord
	current_coords := e.chars.current_coord
	input_symbols := e.chars.input_symbol
	visual_symbols := e.chars.visual_symbol
	visual_fg := e.chars.visual_fg
	for id in engine.group_slice(s.rows, s.redraw_row) {
		current_coords[id] = input_coords[id]
		visual_symbols[id] = input_symbols[id]
		visual_fg[id] = s.final_colors[id]
	}
	s.redraw_row += 1
	engine.frame(e, s.characters[:])
	return true
}
