package effects

import "../engine"

import "core:fmt"

// colorshift — one shared palette cycles across per-character offsets, then
// settles into final colors. Cycles are scalar time, never duplicated frames.

Colorshift_Config :: struct {
	gradient_stops:           [dynamic]engine.Color,
	gradient_steps:           [dynamic]int,
	gradient_frames:          int,
	no_travel:                bool,
	travel_direction:         engine.Gradient_Direction,
	reverse_travel_direction: bool,
	no_loop:                  bool,
	cycles:                   int,
	skip_final_gradient:      bool,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

colorshift_config_default :: proc() -> Colorshift_Config {
	cfg := Colorshift_Config {
		gradient_frames          = 2,
		travel_direction         = .Radial,
		cycles                   = 3,
		final_gradient_direction = .Vertical,
	}
	append(
		&cfg.gradient_stops,
		..[]engine.Color {
			engine.Color{0xe8, 0x14, 0x16},
			engine.Color{0xff, 0xa5, 0x00},
			engine.Color{0xfa, 0xeb, 0x36},
			engine.Color{0x79, 0xc3, 0x14},
			engine.Color{0x48, 0x7d, 0xe7},
			engine.Color{0x4b, 0x36, 0x9d},
			engine.Color{0x70, 0x36, 0x9d},
		},
	)
	append(&cfg.gradient_steps, 12)
	append(&cfg.final_gradient_stops, ..cfg.gradient_stops[:])
	append(&cfg.final_gradient_steps, 12)
	return cfg
}

colorshift_parse :: proc(cfg: ^Colorshift_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--gradient-stops":
			if !parse_colors_flag(&cfg.gradient_stops, args, &i, value, has_value) do return false
		case "--gradient-steps":
			if !parse_ints_flag(&cfg.gradient_steps, args, &i, value, has_value) do return false
		case "--gradient-frames":
			if !parse_int_flag(&cfg.gradient_frames, args, &i, value, has_value) do return false
		case "--no-travel":
			cfg.no_travel = true
		case "--travel-direction":
			if !parse_gdir_flag(&cfg.travel_direction, args, &i, value, has_value) do return false
		case "--reverse-travel-direction":
			cfg.reverse_travel_direction = true
		case "--no-loop":
			cfg.no_loop = true
		case "--cycles":
			if !parse_int_flag(&cfg.cycles, args, &i, value, has_value) do return false
		case "--skip-final-gradient":
			cfg.skip_final_gradient = true
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown colorshift option: ", name)
			return false
		}
	}
	return true
}

Colorshift_State :: struct {
	config:            Colorshift_Config,
	gradient:          [dynamic]engine.Color, // one shared palette
	shifts:            [dynamic]int, // indexed like particle_sets.input
	final_colors:      [dynamic]engine.Color, // indexed like particle_sets.input
	appearances:       [dynamic]engine.Appearance_Id,
	tick:              int,
	palette_index:     int,
	palette_tick:      int,
	color_handling:    engine.Existing_Color_Handling,
	dynamic_has_color: bool,
}

colorshift_build :: proc(s: ^Colorshift_State, e: ^engine.Engine) {
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

	s.gradient = engine.gradient_make(
		s.config.gradient_stops[:],
		s.config.gradient_steps[:],
		!s.config.no_loop,
	)
	assert(s.config.gradient_frames >= 1)
	ids := e.particle_sets.input[:]
	s.color_handling = e.cfg.existing_color_handling
	s.shifts = make([dynamic]int, len(ids))
	if s.config.cycles != 0 && !s.config.skip_final_gradient {
		s.final_colors = make([dynamic]engine.Color, len(ids))
	}
	initial_coords := e.particles.initial_coord
	visible_flags := e.particles.flags

	n := len(s.gradient)

	for id, i in ids {
		c := initial_coords[id]
		visible_flags[id] += {.Visible}

		// A rotation is two contiguous slices of the shared gradient. Keep the
		// offset scalar instead of allocating one color array per character.
		k := 0
		if !s.config.no_travel {
			index: f64
			switch s.config.travel_direction {
			case .Horizontal:
				index = f64(c.column) / f64(e.canvas.right)
			case .Vertical:
				index = f64(c.row) / f64(e.canvas.top)
			case .Diagonal:
				index = f64(c.row + c.column) / f64(e.canvas.right + e.canvas.top)
			case .Radial:
				d, _ := engine.find_normalized_distance_from_center(
					e.canvas.text_bottom,
					e.canvas.text_top,
					e.canvas.text_left,
					e.canvas.text_right,
					c,
				)
				index = d
			}
			shift := int(f64(n) * index)
			if s.config.reverse_travel_direction do shift = -shift
			k = shift < 0 ? max(n + shift, 0) : min(shift, n)
		}
		if k == n do k = 0
		s.shifts[i] = k
		engine.set_foreground(e, id, s.gradient[k])
		if len(s.final_colors) != 0 {
			s.final_colors[i] = engine.gradient_sample(final_sampler, final_spectrum[:], c)
		}
		if s.color_handling == .Dynamic &&
		   (engine.get_initial_appearance(e, engine.Particle_Id(id)).colors.fg != nil ||
				   engine.get_initial_appearance(e, engine.Particle_Id(id)).colors.bg != nil) {
			s.dynamic_has_color = true
		}
	}

	s.appearances = make([dynamic]engine.Appearance_Id, n)
	for color, k in s.gradient {
		s.appearances[k] = engine.prepare_appearance(e, engine.Appearance{colors = {fg = color}})
	}
}

colorshift_next :: proc(s: ^Colorshift_State, e: ^engine.Engine) -> bool #no_bounds_check {
	ids := e.particle_sets.input[:]
	n := len(s.gradient)
	frames := s.config.gradient_frames
	cycle_ticks := s.config.cycles * n * frames
	if s.config.cycles == 0 || s.tick < cycle_ticks {
		if s.palette_tick == 0 {
			for base := 0; base < len(ids); base += 8 {
				count := min(8, len(ids) - base)
				codes: [8]engine.Appearance_Id
				for lane in 0 ..< count {
					i := base + lane
					index := s.shifts[i] + s.palette_index
					if index >= n do index -= n
					codes[lane] = s.appearances[index]
				}
				engine.set_appearances(e, ids[base:base + count], codes[:count])
			}
		}
		s.palette_tick += 1
		if s.palette_tick == frames {
			s.palette_tick = 0
			s.palette_index += 1
			if s.palette_index == n do s.palette_index = 0
		}
	} else {
		if s.config.skip_final_gradient do return false
		transition_tick := s.tick - cycle_ticks
		if s.color_handling == .Dynamic && transition_tick >= (s.dynamic_has_color ? 9 * frames : frames) do return false
		transition_step := transition_tick / frames
		transition_steps :: 8
		if transition_step > transition_steps do return false
		if transition_tick % frames == 0 {
			for id, i in ids {
				appearance_symbol := e.particles.initial_symbol[engine.Particle_Id(id)]
				appearance := engine.Appearance{}
				start_index := s.shifts[i] - 1
				if start_index < 0 do start_index += n
				start := s.gradient[start_index]
				if s.color_handling == .Dynamic {
					appearance.colors = engine.tween(engine.Color_Pair{start, start}, engine.get_initial_appearance(e, engine.Particle_Id(id)).colors, transition_steps, transition_step)
				} else {
					appearance.colors.fg = engine.tween(
						start,
						s.final_colors[i],
						transition_steps,
						transition_step,
					)
				}
				engine.set_symbol(e, id, appearance_symbol)
				engine.set_appearance(e, id, appearance)
			}
		}
	}
	s.tick += 1
	return true
}
