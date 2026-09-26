package effects

import "../engine"

import "core:fmt"
import "core:math/ease"

// middleout — characters condense onto the middle row/column, then expand to
// their home coordinates.

Expand_Direction :: enum {
	Vertical,
	Horizontal,
}

Middleout_Config :: struct {
	starting_color:           engine.Color,
	expand_direction:         Expand_Direction,
	center_movement_speed:    f64,
	full_movement_speed:      f64,
	center_easing:            ease.Ease,
	full_easing:              ease.Ease,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

middleout_config_default :: proc() -> Middleout_Config {
	cfg := Middleout_Config {
		starting_color           = engine.Color{0xff, 0xff, 0xff},
		expand_direction         = .Vertical,
		center_movement_speed    = 0.6,
		full_movement_speed      = 0.6,
		center_easing            = .Sine_In_Out,
		full_easing              = .Sine_In_Out,
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

middleout_parse :: proc(cfg: ^Middleout_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--starting-color":
			if !parse_color_flag(&cfg.starting_color, args, &i, value, has_value) do return false
		case "--expand-direction":
			v, ok := opt_value(args, &i, value, has_value)
			if !ok do return false
			switch v {
			case "vertical":
				cfg.expand_direction = .Vertical
			case "horizontal":
				cfg.expand_direction = .Horizontal
			case:
				return false
			}
		case "--center-movement-speed":
			if !parse_float_flag(&cfg.center_movement_speed, args, &i, value, has_value) || cfg.center_movement_speed <= 0 do return false
		case "--full-movement-speed":
			if !parse_float_flag(&cfg.full_movement_speed, args, &i, value, has_value) || cfg.full_movement_speed <= 0 do return false
		case "--center-easing":
			if !parse_ease_flag(&cfg.center_easing, args, &i, value, has_value) do return false
		case "--full-easing":
			if !parse_ease_flag(&cfg.full_easing, args, &i, value, has_value) do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown middleout option: ", name)
			return false
		}
	}
	return true
}

Middleout_State :: struct {
	config:           Middleout_Config,
	characters:       [dynamic]engine.Particle_Id,
	final_colors:     [dynamic]engine.Color,
	center_targets:   [dynamic]engine.Coord,
	center_max_steps: [dynamic]int,
	full_max_steps:   [dynamic]int,
	center_limit:     int,
	full_limit:       int,
	phase_full:       bool,
	phase_tick:       int,
	color_handling:   engine.Existing_Color_Handling,
}

middleout_build :: proc(s: ^Middleout_State, e: ^engine.Engine) {
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
	s.final_colors = make([dynamic]engine.Color, n)
	s.center_targets = make([dynamic]engine.Coord, n)
	s.center_max_steps = make([dynamic]int, n)
	s.full_max_steps = make([dynamic]int, n)
	for id, i in s.characters {
		c := e.particles.initial_coord[id]
		s.final_colors[i] = engine.gradient_sample(sampler, spectrum[:], c)

		e.particles.current_coord[id] = e.canvas.center
		mid := engine.coord(c.column, e.canvas.center_row)
		if s.config.expand_direction == .Horizontal do mid = engine.coord(e.canvas.center_column, c.row)
		s.center_targets[i] = mid
		s.center_max_steps[i] = max(
			engine.round_half_even(
				engine.line_length(e.canvas.center, mid, true) / s.config.center_movement_speed,
			),
			1,
		)
		s.full_max_steps[i] = max(
			engine.round_half_even(
				engine.line_length(mid, c, true) / s.config.full_movement_speed,
			),
			1,
		)
		s.center_limit = max(s.center_limit, s.center_max_steps[i])
		s.full_limit = max(s.full_limit, s.full_max_steps[i])
		style := engine.get_initial_visual(e, engine.Particle_Id(id))
		fade_ticks := s.color_handling == .Dynamic && style.fg == nil && style.bg == nil ? 6 : 66
		s.full_limit = max(s.full_limit, fade_ticks)
		engine.set_visual(
			e,
			id,
			engine.Visual {
				symbol = engine.get_initial_visual(e, engine.Particle_Id(id)).symbol,
				fg = s.config.starting_color,
			},
		)
		e.particles.is_visible[id] = true
	}
}

middleout_next :: proc(s: ^Middleout_State, e: ^engine.Engine) -> bool {
	if len(s.characters) == 0 do return false
	if s.phase_full && s.phase_tick >= s.full_limit do return false
	if !s.phase_full && s.phase_tick >= s.center_limit {
		s.phase_full = true
		s.phase_tick = 0
	}
	for id, i in s.characters {
		maximum := s.full_max_steps[i] if s.phase_full else s.center_max_steps[i]
		if s.phase_tick >= maximum do continue
		progress := f64(s.phase_tick + 1) / f64(maximum)
		origin := s.center_targets[i] if s.phase_full else e.canvas.center
		target := e.particles.initial_coord[id] if s.phase_full else s.center_targets[i]
		easing := s.config.full_easing if s.phase_full else s.config.center_easing
		engine.set_particle(
			e,
			id,
			coord = engine.coord_on_line(origin, target, ease.ease(easing, progress)),
		)
	}
	if s.phase_full && s.phase_tick <= 60 && s.phase_tick % 6 == 0 {
		gradient_step := s.phase_tick / 6
		for id, i in s.characters {
			visual := engine.get_visual(e, id)
			if s.color_handling == .Dynamic {
				engine.dynamic_gradient_to_input(
					&visual,
					s.config.starting_color,
					engine.get_initial_visual(e, id),
					10,
					gradient_step,
				)
			} else {
				visual.fg = engine.gradient_between_step(
					s.config.starting_color,
					s.final_colors[i],
					10,
					gradient_step,
				)
			}
			engine.set_visual(e, id, visual)
		}
	}
	s.phase_tick += 1
	return true
}
