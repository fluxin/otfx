package effects

import engine "../engine"

import "core:fmt"
import rand "core:math/rand"

Burn_Char_Order :: [9]string{"'", ".", "▖", "▙", "█", "▜", "▀", "▝", "."}
Burn_Smoke_Symbols :: [6]string{".", ",", "'", "`", "#", "*"}

Burn_Config :: struct {
	starting_color:           engine.Color,
	burn_colors:              [dynamic]engine.Color,
	smoke_chance:             f64,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

burn_config_default :: proc() -> Burn_Config {
	cfg := Burn_Config {
		starting_color           = engine.Color{0x83, 0x73, 0x73},
		smoke_chance             = 0.5,
		final_gradient_direction = .Vertical,
	}
	append(
		&cfg.burn_colors,
		..[]engine.Color {
			engine.Color{0xff, 0xff, 0xff},
			engine.Color{0xff, 0xf7, 0x5d},
			engine.Color{0xfe, 0x65, 0x0d},
			engine.Color{0x8A, 0x00, 0x3C},
			engine.Color{0x51, 0x01, 0x00},
		},
	)
	append(
		&cfg.final_gradient_stops,
		engine.Color{0x00, 0xc3, 0xff},
		engine.Color{0xff, 0xff, 0x1c},
	)
	append(&cfg.final_gradient_steps, 12)
	return cfg
}

burn_parse :: proc(cfg: ^Burn_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--starting-color":
			if !parse_color_flag(&cfg.starting_color, args, &i, value, has_value) do return false
		case "--burn-colors":
			if !parse_colors_flag(&cfg.burn_colors, args, &i, value, has_value) do return false
		case "--smoke-chance":
			if !parse_float_flag(&cfg.smoke_chance, args, &i, value, has_value) || cfg.smoke_chance < 0 || cfg.smoke_chance > 1 do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown burn option: ", name)
			return false
		}
	}
	return true
}

Burn_State :: struct {
	config:            Burn_Config,
	characters:        [dynamic]engine.Char_Id,
	final_colors:      [dynamic]engine.Color,
	start_ticks:       [dynamic]int,
	order:             [dynamic]int,
	next_character:    int,
	fire_palette:      [dynamic]engine.Color,
	fire_symbols:      [dynamic]string,
	smoke_ids:         [dynamic]engine.Char_Id,
	smoke_start_ticks: [dynamic]int,
	smoke_origins:     [dynamic]engine.Coord,
	smoke_targets:     [dynamic]engine.Coord,
	smoke_steps:       [dynamic]int,
	next_smoke:        int,
	render_ids:        [dynamic]engine.Char_Id,
	tick:              int,
}

burn_build :: proc(s: ^Burn_State, e: ^engine.Engine) {
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
	s.fire_palette = engine.gradient_with_steps(s.config.burn_colors[:], 10, false)
	s.fire_symbols = make([dynamic]string, len(s.fire_palette))
	cycle_symbols := Burn_Char_Order
	symbol_index := 0
	for i in 0 ..< len(s.fire_symbols) {
		s.fire_symbols[i] = cycle_symbols[symbol_index]
		symbol_index += 1
		if symbol_index == len(cycle_symbols) do symbol_index = 0
	}

	query := engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas}
	s.characters = engine.get_characters(query, engine.filter_input(), .Top_Bottom_Left_Right)
	n := len(s.characters)
	s.final_colors = make([dynamic]engine.Color, n)
	s.start_ticks = make([dynamic]int, n)
	s.order = make([dynamic]int, n)
	s.smoke_start_ticks = make([dynamic]int, n)
	s.smoke_origins = make([dynamic]engine.Coord, n)
	s.smoke_targets = make([dynamic]engine.Coord, n)
	s.smoke_steps = make([dynamic]int, n)

	input_coords := e.chars.input_coord
	visual_fg := e.chars.visual_fg
	visible := e.chars.is_visible
	for id, i in s.characters {
		s.final_colors[i] = engine.gradient_sample(
			final_sampler,
			final_spectrum[:],
			input_coords[id],
		)
		s.start_ticks[i] = -1
		s.smoke_start_ticks[i] = -1
		s.order[i] = i
		visual_fg[id] = s.config.starting_color
		visible[id] = true
	}
	rand.shuffle(s.order[:])

	// At most one smoke trail can be born from each source character. Allocate
	// that exact maximum up front; no hidden per-frame particle allocation.
	for _ in 0 ..< n {
		id := engine.add_character(e, ".", engine.coord(0, 0))
		e.chars.layer[id] = 2
		e.chars.is_visible[id] = false
		append(&s.smoke_ids, id)
	}
	append(&s.render_ids, ..s.characters[:])
	append(&s.render_ids, ..s.smoke_ids[:])
}

burn_emit_smoke :: proc(s: ^Burn_State, e: ^engine.Engine, source_index: int) {
	if rand.float64() > s.config.smoke_chance || s.next_smoke >= len(s.smoke_ids) do return
	particle := s.next_smoke
	s.next_smoke += 1
	id := s.smoke_ids[particle]
	origin := e.chars.input_coord[s.characters[source_index]]
	target := engine.coord(rand.int_range(origin.column - 4, origin.column + 5), e.canvas.top + 1)
	s.smoke_start_ticks[particle] = s.tick
	s.smoke_origins[particle] = origin
	s.smoke_targets[particle] = target
	s.smoke_steps[particle] = max(
		engine.round_half_even(engine.line_length(origin, target, true) / 0.5),
		1,
	)
	e.chars.current_coord[id] = origin
	symbols := Burn_Smoke_Symbols
	e.chars.visual_symbol[id] = symbols[rand.int_max(len(symbols))]
	e.chars.visual_fg[id] = engine.Color{0x50, 0x4F, 0x4F}
	e.chars.is_visible[id] = true
}

burn_next :: proc(s: ^Burn_State, e: ^engine.Engine) -> bool {
	fire_ticks := len(s.fire_palette) * 4
	final_ticks :: 36 // 9 entries, four frames each
	active := s.next_character < len(s.order)
	for start_tick in s.start_ticks {
		if start_tick >= 0 && s.tick - start_tick < fire_ticks + final_ticks {
			active = true
			break
		}
	}
	if !active {
		for i in 0 ..< s.next_smoke {
			age := s.tick - s.smoke_start_ticks[i]
			if age < max(s.smoke_steps[i], 100) {
				active = true
				break
			}
		}
	}
	if !active do return false

	for _ in 0 ..< rand.int_range(2, 5) {
		if s.next_character >= len(s.order) do break
		i := s.order[s.next_character]
		s.next_character += 1
		s.start_ticks[i] = s.tick
	}

	input_symbols := e.chars.input_symbol
	visual_symbols := e.chars.visual_symbol
	visual_fg := e.chars.visual_fg
	for id, i in s.characters {
		start_tick := s.start_ticks[i]
		if start_tick < 0 do continue
		age := s.tick - start_tick
		if age < fire_ticks {
			entry := age / 4
			visual_symbols[id] = s.fire_symbols[entry]
			visual_fg[id] = s.fire_palette[entry]
		} else {
			if age == fire_ticks do burn_emit_smoke(s, e, i)
			visual_symbols[id] = input_symbols[id]
			visual_fg[id] = engine.gradient_between_step(
				s.fire_palette[len(s.fire_palette) - 1],
				s.final_colors[i],
				8,
				min((age - fire_ticks) / 4, 8),
			)
		}
	}

	smoke_start := e.chars.current_coord
	smoke_visible := e.chars.is_visible
	smoke_fg := e.chars.visual_fg
	smoke_gradient_start := engine.Color{0x50, 0x4F, 0x4F}
	smoke_gradient_end := engine.Color{0xC7, 0xC7, 0xC7}
	for i in 0 ..< s.next_smoke {
		age := s.tick - s.smoke_start_ticks[i]
		life := max(s.smoke_steps[i], 100)
		id := s.smoke_ids[i]
		if age >= life {
			smoke_visible[id] = false
			continue
		}
		progress := f64(min(age + 1, s.smoke_steps[i])) / f64(s.smoke_steps[i])
		smoke_start[id] = engine.coord_on_line(s.smoke_origins[i], s.smoke_targets[i], progress)
		smoke_fg[id] = engine.gradient_between_step(
			smoke_gradient_start,
			smoke_gradient_end,
			9,
			min(age / 10, 9),
		)
	}
	s.tick += 1
	engine.frame(e, s.render_ids[:])
	return true
}
