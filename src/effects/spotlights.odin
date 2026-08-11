package effects

import engine "../engine"

import "core:fmt"
import ease "core:math/ease"
import rand "core:math/rand"

Spotlights_Config :: struct {
	beam_width_ratio:         f64,
	beam_falloff:             f64,
	search_duration:          int,
	search_speed_range:       Float_Range_Value,
	spotlight_count:          int,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

spotlights_config_default :: proc() -> Spotlights_Config {
	cfg := Spotlights_Config {
		beam_width_ratio         = 2,
		beam_falloff             = 0.3,
		search_duration          = 550,
		search_speed_range       = {0.35, 0.75},
		spotlight_count          = 3,
		final_gradient_direction = .Vertical,
	}
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

spotlights_parse :: proc(cfg: ^Spotlights_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--beam-width-ratio":
			if !parse_float_flag(&cfg.beam_width_ratio, args, &i, value, has_value) || cfg.beam_width_ratio <= 0 do return false
		case "--beam-falloff":
			if !parse_float_flag(&cfg.beam_falloff, args, &i, value, has_value) || cfg.beam_falloff < 0 do return false
		case "--search-duration":
			if !parse_int_flag(&cfg.search_duration, args, &i, value, has_value) || cfg.search_duration <= 0 do return false
		case "--search-speed-range":
			if !parse_float_range_flag(&cfg.search_speed_range, args, &i, value, has_value) || cfg.search_speed_range.lo <= 0 do return false
		case "--spotlight-count":
			if !parse_int_flag(&cfg.spotlight_count, args, &i, value, has_value) || cfg.spotlight_count <= 0 do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown spotlights option: ", name)
			return false
		}
	}
	return true
}

Spotlights_Phase :: enum {
	Search,
	Converge,
	Expand,
}

Spotlights_State :: struct {
	config:           Spotlights_Config,
	characters:       [dynamic]engine.Char_Id,
	bright_colors:    [dynamic]engine.Color,
	dark_colors:      [dynamic]engine.Color,
	spot_positions:   [dynamic]engine.Coord,
	spot_origins:     [dynamic]engine.Coord,
	spot_targets:     [dynamic]engine.Coord,
	spot_controls:    [dynamic]engine.Coord,
	spot_steps:       [dynamic]int,
	spot_ticks:       [dynamic]int,
	spot_speeds:      [dynamic]f64,
	phase:            Spotlights_Phase,
	phase_tick:       int,
	illuminate_range: int,
	expand_limit:     int,
}

spotlights_new_target :: proc(s: ^Spotlights_State, e: ^engine.Engine, i: int) {
	origin := s.spot_positions[i]
	target := engine.canvas_random_coord(e.canvas, false, false)
	control := engine.canvas_random_coord(e.canvas, true, false)
	s.spot_origins[i] = origin
	s.spot_targets[i] = target
	s.spot_controls[i] = control
	s.spot_speeds[i] = rand.float64_range(
		s.config.search_speed_range.lo,
		s.config.search_speed_range.hi,
	)
	s.spot_steps[i] = max(
		engine.round_half_even(
			engine.quadratic_bezier_length(origin, control, target) / s.spot_speeds[i],
		),
		1,
	)
	s.spot_ticks[i] = 0
}

spotlights_build :: proc(s: ^Spotlights_State, e: ^engine.Engine) {
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
	s.characters = engine.get_characters(query, engine.CHAR_FILTER_INPUT, .Top_Bottom_Left_Right)
	n := len(s.characters)
	s.bright_colors = make([dynamic]engine.Color, n)
	s.dark_colors = make([dynamic]engine.Color, n)
	input_coords := e.chars.input_coord
	visible := e.chars.is_visible
	visual_fg := e.chars.visual
	for id, i in s.characters {
		bright := engine.gradient_sample(sampler, spectrum[:], input_coords[id])
		s.bright_colors[i] = bright
		s.dark_colors[i] = engine.adjust_color_brightness(bright, 0.2)
		visual_fg[id].fg = s.dark_colors[i]
		visible[id] = true
	}

	count := s.config.spotlight_count
	s.spot_positions = make([dynamic]engine.Coord, count)
	s.spot_origins = make([dynamic]engine.Coord, count)
	s.spot_targets = make([dynamic]engine.Coord, count)
	s.spot_controls = make([dynamic]engine.Coord, count)
	s.spot_steps = make([dynamic]int, count)
	s.spot_ticks = make([dynamic]int, count)
	s.spot_speeds = make([dynamic]f64, count)
	for i in 0 ..< count {
		s.spot_positions[i] = engine.canvas_random_coord(e.canvas, true, false)
		spotlights_new_target(s, e, i)
	}
	s.illuminate_range = max(
		int(f64(min(e.canvas.right, e.canvas.top)) / s.config.beam_width_ratio),
		1,
	)
	s.expand_limit = max(int(f64(max(e.canvas.right, e.canvas.top)) / 1.5), s.illuminate_range)
	s.phase = .Search
}

spotlights_update_positions :: proc(s: ^Spotlights_State, e: ^engine.Engine) -> bool {
	all_arrived := true
	for i in 0 ..< len(s.spot_positions) {
		steps := s.spot_steps[i]
		tick := s.spot_ticks[i]
		if tick < steps {
			all_arrived = false
			progress := f64(tick + 1) / f64(steps)
			ease_type := s.phase == .Converge ? ease.Ease.Sine_In_Out : ease.Ease.Quadratic_In_Out
			s.spot_positions[i] = engine.coord_on_quadratic_bezier(
				s.spot_origins[i],
				s.spot_controls[i],
				s.spot_targets[i],
				ease.ease(ease_type, progress),
			)
			s.spot_ticks[i] += 1
		}
		if s.phase == .Search && s.spot_ticks[i] == steps do spotlights_new_target(s, e, i)
	}
	return all_arrived
}

spotlights_next :: proc(s: ^Spotlights_State, e: ^engine.Engine) -> ([]engine.Char_Id, bool) {
	if s.phase == .Search {
		spotlights_update_positions(s, e)
		s.phase_tick += 1
		if s.phase_tick == s.config.search_duration {
			s.phase = .Converge
			s.phase_tick = 0
			for i in 0 ..< len(s.spot_positions) {
				s.spot_origins[i] = s.spot_positions[i]
				s.spot_targets[i] = e.canvas.center
				s.spot_controls[i] = s.spot_positions[i]
				s.spot_steps[i] = max(
					engine.round_half_even(
						engine.line_length(s.spot_positions[i], e.canvas.center, true) / 0.5,
					),
					1,
				)
				s.spot_ticks[i] = 0
			}
		}
	} else if s.phase == .Converge {
		if spotlights_update_positions(s, e) {
			s.phase = .Expand
			for i in 0 ..< len(s.spot_positions) do s.spot_positions[i] = e.canvas.center
		}
	} else {
		if s.illuminate_range > s.expand_limit do return nil, false
		s.illuminate_range += 1
	}

	input_coords := e.chars.input_coord
	visual_fg := e.chars.visual
	for id, i in s.characters {
		p := input_coords[id]
		nearest := engine.line_length(s.spot_positions[0], p, true)
		for j in 1 ..< len(s.spot_positions) do nearest = min(nearest, engine.line_length(s.spot_positions[j], p, true))
		if nearest > f64(s.illuminate_range) {
			visual_fg[id].fg = s.dark_colors[i]
			continue
		}
		bright := s.bright_colors[i]
		if s.config.beam_falloff > 0 &&
		   nearest > f64(s.illuminate_range) * (1 - s.config.beam_falloff) {
			start := f64(s.illuminate_range) * (1 - s.config.beam_falloff)
			factor := max(
				1 - (nearest - start) / (f64(s.illuminate_range) * s.config.beam_falloff),
				0.2,
			)
			visual_fg[id].fg = engine.adjust_color_brightness(bright, factor)
		} else {
			visual_fg[id].fg = bright
		}
	}
	return s.characters[:], true
}
