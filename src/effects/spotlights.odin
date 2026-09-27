package effects

import "../engine"

import "core:container/bit_array"
import "core:fmt"
import "core:math"
import "core:math/ease"

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
	config:                   Spotlights_Config,
	characters:               [dynamic]engine.Particle_Id,
	rows:                     []engine.Span, // spans into the immutable, row-ordered characters
	lit:                      [dynamic]int,
	candidates:               bit_array.Bit_Array,
	bright_colors:            [dynamic]engine.Color,
	bright_hsl:               []engine.HSL_Color,
	bright_bg_hsl:            []engine.HSL_Color,
	dark_colors:              [dynamic]engine.Color,
	bright_bg:                [dynamic]Maybe(engine.Color),
	dark_bg:                  [dynamic]Maybe(engine.Color),
	spot_positions:           [dynamic]engine.Coord,
	spot_origins:             [dynamic]engine.Coord,
	spot_targets:             [dynamic]engine.Coord,
	spot_controls:            [dynamic]engine.Coord,
	spot_steps:               [dynamic]int,
	spot_ticks:               [dynamic]int,
	spot_speeds:              [dynamic]f64,
	phase:                    Spotlights_Phase,
	phase_tick:               int,
	illuminate_range:         int,
	expand_limit:             int,
	color_handling:           engine.Existing_Color_Handling,
	illumination_initialized: bool,
}

spotlights_new_target :: proc(s: ^Spotlights_State, e: ^engine.Engine, i: int) {
	origin := s.spot_positions[i]
	target := engine.canvas_random_coord(e.canvas, false, false)
	control := engine.canvas_random_coord(e.canvas, true, false)
	s.spot_origins[i] = origin
	s.spot_targets[i] = target
	s.spot_controls[i] = control
	s.spot_speeds[i] = engine.random_float_range(
		s.config.search_speed_range.lo,
		s.config.search_speed_range.hi,
	)
	s.spot_steps[i] = max(
		engine.round_to_int(
			engine.quadratic_bezier_length(origin, control, target) / s.spot_speeds[i],
		),
		1,
	)
	s.spot_ticks[i] = 0
}

spotlights_build :: proc(s: ^Spotlights_State, e: ^engine.Engine) {
	s.color_handling = e.cfg.existing_color_handling
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
	query := engine.Particle_Query {
		e.particle_sets,
		e.particles.initial_coord[:len(e.particles)],
		e.canvas,
	}
	s.characters = engine.get_particles(
		query,
		engine.PARTICLE_FILTER_INPUT,
		.Top_Bottom_Left_Right,
	)
	n := len(s.characters)
	s.rows = make([]engine.Span, e.canvas.top + 1)
	reserve(&s.lit, n)
	bit_array.init(&s.candidates, n)
	s.bright_colors = make([dynamic]engine.Color, n)
	s.dark_colors = make([dynamic]engine.Color, n)
	s.bright_hsl = make([]engine.HSL_Color, n)
	if s.color_handling == .Dynamic do s.bright_bg_hsl = make([]engine.HSL_Color, n)
	s.bright_bg = make([dynamic]Maybe(engine.Color), n)
	s.dark_bg = make([dynamic]Maybe(engine.Color), n)
	initial_coords := e.particles.initial_coord
	visible_flags := e.particles.flags

	for id, i in s.characters {
		row := &s.rows[initial_coords[id].row]
		if row.len == 0 do row.start = i
		row.len += 1
		bright := engine.gradient_sample(sampler, spectrum[:], initial_coords[id])
		if s.color_handling == .Dynamic {
			style := engine.get_initial_appearance(e, engine.Particle_Id(id))
			bright = engine.Color{0x80, 0x80, 0x80}
			if fg, ok := style.colors.fg.?; ok do bright = fg
			s.bright_bg[i] = style.colors.bg
			if bg, ok := style.colors.bg.?; ok {
				s.bright_bg_hsl[i] = engine.color_to_hsl(bg)
				s.dark_bg[i] = engine.adjust_color_brightness(s.bright_bg_hsl[i], 0.2)
			}
		}
		s.bright_colors[i] = bright
		s.bright_hsl[i] = engine.color_to_hsl(bright)
		s.dark_colors[i] = engine.adjust_color_brightness(s.bright_hsl[i], 0.2)
		engine.set_foreground(e, id, s.dark_colors[i])
		engine.set_background(e, id, s.color_handling == .Dynamic ? s.dark_bg[i] : nil)
		visible_flags[id] += {.Visible}
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
	s.illumination_initialized = false
}

spotlights_update_positions :: proc(
	s: ^Spotlights_State,
	e: ^engine.Engine,
) -> (
	all_arrived, moved: bool,
) {
	all_arrived = true
	for i in 0 ..< len(s.spot_positions) {
		steps := s.spot_steps[i]
		tick := s.spot_ticks[i]
		if tick < steps {
			all_arrived = false
			progress := f64(tick + 1) / f64(steps)
			ease_type := s.phase == .Converge ? ease.Ease.Sine_In_Out : ease.Ease.Quadratic_In_Out
			position := engine.coord_on_quadratic_bezier(
				s.spot_origins[i],
				s.spot_controls[i],
				s.spot_targets[i],
				ease.ease(ease_type, progress),
			)
			moved = moved || position != s.spot_positions[i]
			s.spot_positions[i] = position
			s.spot_ticks[i] += 1
		}
		if s.phase == .Search && s.spot_ticks[i] == steps do spotlights_new_target(s, e, i)
	}
	return
}

spotlights_next :: proc(s: ^Spotlights_State, e: ^engine.Engine) -> bool #no_bounds_check {
	// Illumination depends on integer positions, range, and the Expand color rule.
	restore_input := false
	repaint := !s.illumination_initialized || s.phase == .Expand
	if s.phase == .Search {
		_, moved := spotlights_update_positions(s, e)
		repaint = repaint || moved
		s.phase_tick += 1
		if s.phase_tick == s.config.search_duration {
			s.phase = .Converge
			s.phase_tick = 0
			for i in 0 ..< len(s.spot_positions) {
				s.spot_origins[i] = s.spot_positions[i]
				s.spot_targets[i] = e.canvas.center
				s.spot_controls[i] = s.spot_positions[i]
				s.spot_steps[i] = max(
					engine.round_to_int(
						engine.line_length(s.spot_positions[i], e.canvas.center, true) / 0.5,
					),
					1,
				)
				s.spot_ticks[i] = 0
			}
		}
	} else if s.phase == .Converge {
		arrived, moved := spotlights_update_positions(s, e)
		repaint = repaint || moved
		if arrived {
			s.phase = .Expand
			restore_input = s.color_handling == .Dynamic
			for i in 0 ..< len(s.spot_positions) do s.spot_positions[i] = e.canvas.center
			repaint = true
		}
	} else {
		if s.illuminate_range > s.expand_limit do return false
	}
	if !repaint do return true
	s.illumination_initialized = true

	initial_coords := e.particles.initial_coord
	// Every spotlight is at the center during expansion; one distance suffices.
	spot_count := 1 if s.phase == .Expand else len(s.spot_positions)
	// Visit the new light bounds plus the old lit set, so departures darken.
	for i in s.lit do bit_array.set(&s.candidates, i)
	clear(&s.lit)
	if restore_input {
		// Dynamic nil foregrounds restore on Expand even outside the light.
		for i in 0 ..< len(s.characters) do bit_array.set(&s.candidates, i)
	} else {
		for spot in s.spot_positions[:spot_count] {
			bottom := max(spot.row - s.illuminate_range / 2, 1)
			top := min(spot.row + s.illuminate_range / 2, e.canvas.top)
			left, right := spot.column - s.illuminate_range, spot.column + s.illuminate_range
			for row_index := bottom; row_index <= top; row_index += 1 {
				row := s.rows[row_index]
				for id, offset in s.characters[row.start:row.start + row.len] {
					column := initial_coords[id].column
					if column < left do continue
					if column > right do break
					bit_array.set(&s.candidates, row.start + offset)
				}
			}
		}
	}
	radius := f64(s.illuminate_range)
	falloff_start := radius * (1 - s.config.beam_falloff)
	it := bit_array.make_iterator(&s.candidates)
	for i, ok := bit_array.iterate_by_set(&it); ok; i, ok = bit_array.iterate_by_set(&it) {
		id := s.characters[i]
		appearance := engine.get_appearance(e, id)
		if s.color_handling == .Dynamic &&
		   s.phase == .Expand &&
		   engine.get_initial_appearance(e, engine.Particle_Id(id)).colors.fg == nil {
			appearance.colors.fg = nil
			appearance.colors.bg =
				engine.get_initial_appearance(e, engine.Particle_Id(id)).colors.bg
			engine.set_appearance(e, id, appearance)
			continue
		}
		p := initial_coords[id]
		nearest_squared := engine.line_length_squared(s.spot_positions[0], p, true)
		for j in 1 ..< spot_count do nearest_squared = min(nearest_squared, engine.line_length_squared(s.spot_positions[j], p, true))
		if nearest_squared > radius * radius {
			appearance.colors.fg = s.dark_colors[i]
			appearance.colors.bg = s.color_handling == .Dynamic ? s.dark_bg[i] : nil
			engine.set_appearance(e, id, appearance)
			continue
		}
		append(&s.lit, i)
		bright := s.bright_colors[i]
		if s.config.beam_falloff > 0 &&
		   (falloff_start < 0 || nearest_squared > falloff_start * falloff_start) {
			nearest := math.sqrt(nearest_squared)
			factor := max(1 - (nearest - falloff_start) / (radius * s.config.beam_falloff), 0.2)
			appearance.colors.fg = engine.adjust_color_brightness(s.bright_hsl[i], factor)
			if s.color_handling == .Dynamic {
				if s.bright_bg[i] != nil {
					appearance.colors.bg = engine.adjust_color_brightness(
						s.bright_bg_hsl[i],
						factor,
					)
				}
			}
		} else {
			appearance.colors.fg = bright
			appearance.colors.bg = s.color_handling == .Dynamic ? s.bright_bg[i] : nil
		}
		engine.set_appearance(e, id, appearance)
	}
	bit_array.clear(&s.candidates)
	if s.phase == .Expand do s.illuminate_range += 1
	return true
}
