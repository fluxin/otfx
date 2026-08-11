package effects

import engine "../engine"

import "core:fmt"
import rand "core:math/rand"

Smoke_Config :: struct {
	starting_color:           engine.Color,
	smoke_symbols:            [dynamic]string,
	smoke_gradient_stops:     [dynamic]engine.Color,
	use_whole_canvas:         bool,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

smoke_config_default :: proc() -> Smoke_Config {
	cfg := Smoke_Config {
		starting_color           = engine.Color{0x7A, 0x7A, 0x7A},
		final_gradient_direction = .Vertical,
	}
	append(&cfg.smoke_symbols, ..[]string{"░", "▒", "▓", "▒", "░"})
	append(
		&cfg.smoke_gradient_stops,
		engine.Color{0x24, 0x24, 0x24},
		engine.Color{0xFF, 0xFF, 0xFF},
	)
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

smoke_parse :: proc(cfg: ^Smoke_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--starting-color":
			if !parse_color_flag(&cfg.starting_color, args, &i, value, has_value) do return false
		case "--smoke-symbols":
			if !parse_symbols_flag(&cfg.smoke_symbols, args, &i, value, has_value) do return false
		case "--smoke-gradient-stops":
			if !parse_colors_flag(&cfg.smoke_gradient_stops, args, &i, value, has_value) do return false
		case "--use-whole-canvas":
			cfg.use_whole_canvas = true
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown smoke option: ", name)
			return false
		}
	}
	return true
}

// `arrivals[i]` is the flood-front tick for `characters[i]`. The text starts
// visible and the front replaces its glyph with smoke before restoring it
// through the final palette. There are no per-character scenes or graph maps.
Smoke_State :: struct {
	config:        Smoke_Config,
	characters:    [dynamic]engine.Char_Id,
	arrivals:      [dynamic]int,
	final_colors:  [dynamic]engine.Color,
	smoke_palette: [dynamic]engine.Color,
	paint_pairs:   [dynamic]int,
	paint_steps:   [dynamic]int,
	tick:          int,
	last_tick:     int,
}

smoke_build :: proc(s: ^Smoke_State, e: ^engine.Engine) {
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

	// Gradient(smoke stops, reversed final stops, steps=(3, 4)). `gradient_make`
	// repeats the final step count over later pairs, matching that construction.
	stops := make(
		[dynamic]engine.Color,
		0,
		len(s.config.smoke_gradient_stops) + len(s.config.final_gradient_stops),
		context.temp_allocator,
	)
	append(&stops, ..s.config.smoke_gradient_stops[:])
	for i := len(s.config.final_gradient_stops) - 1; i >= 0; i -= 1 do append(&stops, s.config.final_gradient_stops[i])
	s.smoke_palette = engine.gradient_make(stops[:], []int{3, 4}, false)

	query := engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas}
	// Smoke always needs the text rectangle, including its spaces. The
	// whole-canvas option expands that population with outer fill cells.
	filter := engine.Character_Filter{.Input, .Inner_Fill}
	if s.config.use_whole_canvas do filter += {.Outer_Fill}
	s.characters = engine.get_characters(query, filter, .Top_Bottom_Left_Right)
	n := len(s.characters)
	s.arrivals = make([dynamic]int, n)
	s.final_colors = make([dynamic]engine.Color, n)

	within_text := !s.config.use_whole_canvas
	origin := engine.canvas_random_coord(e.canvas, false, within_text)
	input_coords := e.chars.input_coord
	visual_fg := e.chars.visual
	visible := e.chars.is_visible
	for id, i in s.characters {
		p := input_coords[id]
		// A Manhattan flood front has the same contiguous growth property as the
		// original spanning-tree traversal, without retaining adjacency objects.
		arrival := abs(p.column - origin.column) + abs(p.row - origin.row)
		s.arrivals[i] = arrival
		s.last_tick = max(s.last_tick, arrival)
		s.final_colors[i] = engine.gradient_sample(final_sampler, final_spectrum[:], p)
		visual_fg[id].fg = s.config.starting_color
		visible[id] = true
	}

	// smoke frames last 3 ticks; final paint is a 5-tick gradient across every
	// configured stop and then the character-specific destination color.
	paint_entries := 1 + 5 * len(s.config.final_gradient_stops)
	s.paint_pairs = make([dynamic]int, paint_entries)
	s.paint_steps = make([dynamic]int, paint_entries)
	pair, step := 0, 0
	for i in 0 ..< paint_entries {
		s.paint_pairs[i] = pair
		s.paint_steps[i] = step
		step += 1
		if step == 6 {
			pair += 1
			step = 1
		}
	}
	s.last_tick += len(s.smoke_palette) * 3 + paint_entries * 5
}

smoke_paint_color :: proc(
	stops: []engine.Color,
	end: engine.Color,
	pair, step: int,
) -> engine.Color {
	// Gradient(stops..., end, steps=5), sampled from build-time lookup rows so
	// the dense per-character loop only performs direct indexed loads.
	start := stops[pair]
	finish := pair + 1 < len(stops) ? stops[pair + 1] : end
	return engine.gradient_between_step(start, finish, 5, step)
}

smoke_next :: proc(s: ^Smoke_State, e: ^engine.Engine) -> ([]engine.Char_Id, bool) {
	if s.tick == s.last_tick do return nil, false
	smoke_ticks := len(s.smoke_palette) * 3
	paint_entries := 1 + 5 * len(s.config.final_gradient_stops)
	input_symbols := e.chars.input_symbol
	visual_symbols := e.chars.visual
	visual_fg := e.chars.visual
	for id, i in s.characters {
		age := s.tick - s.arrivals[i]
		if age < 0 do continue
		if age < smoke_ticks {
			visual_symbols[id].symbol =
				s.config.smoke_symbols[min(age / 3, len(s.config.smoke_symbols) - 1)]
			visual_fg[id].fg = s.smoke_palette[age / 3]
		} else {
			paint_entry := min((age - smoke_ticks) / 5, paint_entries - 1)
			visual_symbols[id].symbol = input_symbols[id]
			visual_fg[id].fg = smoke_paint_color(
				s.config.final_gradient_stops[:],
				s.final_colors[i],
				s.paint_pairs[paint_entry],
				s.paint_steps[paint_entry],
			)
		}
	}
	s.tick += 1
	return s.characters[:], true
}
