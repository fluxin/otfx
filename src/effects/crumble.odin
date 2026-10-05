package effects

import "../engine"

import "core:fmt"
import "core:math/ease"

@(private = "file", rodata)
Crumble_Dust_Symbols := [3]rune{'*', '.', ','}

Crumble_Config :: struct {
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

crumble_config_default :: proc() -> Crumble_Config {
	cfg := Crumble_Config {
		final_gradient_direction = .Diagonal,
	}
	append(
		&cfg.final_gradient_stops,
		engine.Color{0x5C, 0xE1, 0xFF},
		engine.Color{0xFF, 0x8C, 0x00},
	)
	append(&cfg.final_gradient_steps, 12)
	return cfg
}

crumble_parse :: proc(cfg: ^Crumble_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown crumble option: ", name)
			return false
		}
	}
	return true
}

Crumble_Phase :: enum {
	Falling,
	Vacuuming,
	Resetting,
}

Crumble_State :: struct {
	config:             Crumble_Config,
	characters:         [dynamic]engine.Particle_Id,
	coords:             [dynamic]engine.Coord,
	weak_to_dust_ramp:  engine.Appearance_Ramp,
	weak_to_dust_index: [dynamic]int,
	flash_up_ramp:      engine.Appearance_Ramp,
	flash_up_index:     [dynamic]int,
	flash_down_ramp:    engine.Appearance_Ramp,
	flash_down_index:   [dynamic]int,
	fall_starts:        [dynamic]int,
	fall_steps:         [dynamic]int,
	vacuum_starts:      [dynamic]int,
	vacuum_steps:       [dynamic]int,
	reset_active:       [dynamic]int,
	reset_steps:        [dynamic]int,
	dust_symbols:       [dynamic]rune, // five contiguous symbols per character
	fall_order:         [dynamic]int,
	vacuum_order:       [dynamic]int,
	fall_active:        [dynamic]int,
	vacuum_active:      [dynamic]int,
	next_fall:          int,
	next_vacuum:        int,
	fall_delay:         int,
	min_fall_delay:     int,
	max_fall_delay:     int,
	fall_group_size:    int,
	phase:              Crumble_Phase,
	phase_tick:         int,
	reset_max_ticks:    int,
	color_handling:     engine.Existing_Color_Handling,
}

crumble_build :: proc(s: ^Crumble_State, e: ^engine.Engine) {
	s.color_handling = e.cfg.existing_color_handling
	spectrum := engine.gradient_make(
		s.config.final_gradient_stops[:],
		s.config.final_gradient_steps[:],
		false,
		context.temp_allocator,
	)
	defer delete(spectrum)
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
	reserve(&s.fall_active, n)
	reserve(&s.vacuum_active, n)
	s.coords = make([dynamic]engine.Coord, n)
	s.fall_starts = make([dynamic]int, n)
	s.fall_steps = make([dynamic]int, n)
	s.vacuum_starts = make([dynamic]int, n)
	s.vacuum_steps = make([dynamic]int, n)
	s.reset_steps = make([dynamic]int, n)
	s.reset_active = make([dynamic]int, n)
	for &index, i in s.reset_active do index = i
	s.dust_symbols = make([dynamic]rune, n * 5)
	s.fall_order = make([dynamic]int, n)
	s.vacuum_order = make([dynamic]int, n)
	if n == 0 {
		s.fall_delay, s.min_fall_delay, s.max_fall_delay, s.fall_group_size = 12, 9, 12, 1
		s.phase = .Falling
		return
	}

	weak_tweens := make([]engine.Tween(engine.Appearance), n, context.temp_allocator)
	up_tweens := make([]engine.Tween(engine.Appearance), n, context.temp_allocator)
	down_tweens := make([]engine.Tween(engine.Appearance), n, context.temp_allocator)
	defer delete(weak_tweens, context.temp_allocator)
	defer delete(up_tweens, context.temp_allocator)
	defer delete(down_tweens, context.temp_allocator)

	initial_coords := e.particles.initial_coord
	visible_flags := e.particles.flags
	dust_choices := Crumble_Dust_Symbols
	white := engine.Color{0xFF, 0xFF, 0xFF}
	gray := engine.Color{0x80, 0x80, 0x80}
	weak_gray := engine.adjust_color_brightness(gray, 0.65)
	dust_gray := engine.adjust_color_brightness(gray, 0.55)

	for id, i in s.characters {
		input := initial_coords[id]
		s.coords[i] = input
		final_color := engine.gradient_sample(sampler, spectrum[:], input)
		style := engine.get_initial_appearance(e, id)
		if s.color_handling == .Dynamic {
			weak_fg, dust_fg, up_from_fg, up_to_fg: Maybe(engine.Color)
			weak_bg, dust_bg, up_from_bg, up_to_bg: Maybe(engine.Color)
			if fg, ok := style.colors.fg.?; ok {
				weak_fg = engine.adjust_color_brightness(fg, 0.65)
				dust_fg = engine.adjust_color_brightness(fg, 0.55)
				up_from_fg, up_to_fg = fg, white
			} else if style.colors.bg == nil {
				weak_fg, dust_fg = weak_gray, dust_gray
				up_from_fg, up_to_fg = gray, white
			}
			if bg, ok := style.colors.bg.?; ok {
				weak_bg = engine.adjust_color_brightness(bg, 0.65)
				dust_bg = engine.adjust_color_brightness(bg, 0.55)
				up_from_bg, up_to_bg = bg, white
			}
			weak_tweens[i] = {
				from = {colors = {fg = weak_fg, bg = weak_bg}},
				to   = {colors = {fg = dust_fg, bg = dust_bg}},
			}
			up_tweens[i] = {
				from = {colors = {fg = up_from_fg, bg = up_from_bg}},
				to   = {colors = {fg = up_to_fg, bg = up_to_bg}},
			}
			if style.colors.fg == nil && style.colors.bg == nil {
				down_tweens[i] = {}
			} else {
				down_tweens[i] = {
					from = {colors = {white, white}},
					to   = {colors = style.colors},
				}
			}
		} else {
			weak_fg := engine.adjust_color_brightness(final_color, 0.65)
			dust_fg := engine.adjust_color_brightness(final_color, 0.55)
			weak_tweens[i] = {
				from = {colors = {fg = weak_fg}},
				to   = {colors = {fg = dust_fg}},
			}
			up_tweens[i] = {
				from = {colors = {fg = final_color}},
				to   = {colors = {fg = white}},
			}
			down_tweens[i] = {
				from = {colors = {fg = white}},
				to   = {colors = {fg = final_color}},
			}
		}
		s.fall_starts[i] = -1
		s.vacuum_starts[i] = -1
		s.fall_steps[i] = max(
			engine.round_to_int(
				engine.line_length(input, engine.coord(input.column, e.canvas.bottom), true) /
				0.65,
			),
			1,
		)
		vacuum_start := engine.coord(input.column, e.canvas.bottom)
		vacuum_end := engine.coord(input.column, e.canvas.top)
		vacuum_control := engine.coord(e.canvas.center_column, e.canvas.center_row)
		s.vacuum_steps[i] = max(
			engine.round_to_int(
				engine.quadratic_bezier_length(vacuum_start, vacuum_control, vacuum_end),
			),
			1,
		)
		s.reset_steps[i] = max(engine.round_to_int(engine.line_length(vacuum_end, input, true)), 1)
		reset_tail := 68
		if s.color_handling == .Dynamic && style.colors.fg == nil && style.colors.bg == nil {
			reset_tail = 32
		}
		s.reset_max_ticks = max(s.reset_max_ticks, s.reset_steps[i] + reset_tail)
		for j in 0 ..< 5 do s.dust_symbols[i * 5 + j] = dust_choices[engine.random_below(len(dust_choices))]
		s.fall_order[i] = i
		s.vacuum_order[i] = i
		visible_flags[id] += {.Visible}
	}

	unique_weak, unique_up, unique_down: [dynamic]engine.Tween(engine.Appearance)
	unique_weak, s.weak_to_dust_index = engine.group_values(weak_tweens)
	unique_up, s.flash_up_index = engine.group_values(up_tweens)
	unique_down, s.flash_down_index = engine.group_values(down_tweens)
	defer delete(unique_weak)
	defer delete(unique_up)
	defer delete(unique_down)

	s.weak_to_dust_ramp = engine.ramp_make(e, unique_weak[:], 9)
	s.flash_up_ramp = engine.ramp_make(e, unique_up[:], 6)
	s.flash_down_ramp = engine.ramp_make(e, unique_down[:], 9)

	for id, i in s.characters {
		engine.set_appearance(e, id, engine.ramp_code(s.weak_to_dust_ramp, s.weak_to_dust_index[i], 0))
	}

	engine.random_shuffle(s.fall_order[:])
	engine.random_shuffle(s.vacuum_order[:])
	s.fall_delay, s.min_fall_delay, s.max_fall_delay, s.fall_group_size = 12, 9, 12, 1
	s.phase = .Falling
}

crumble_falling_active :: proc(s: ^Crumble_State) -> bool #no_bounds_check {
	if s.next_fall < len(s.fall_order) do return true
	for i in s.fall_active {
		if s.phase_tick - s.fall_starts[i] < 40 + s.fall_steps[i] do return true
	}
	return false
}

crumble_vacuum_active :: proc(s: ^Crumble_State) -> bool #no_bounds_check {
	if s.next_vacuum < len(s.vacuum_order) do return true
	for i in s.vacuum_active {
		if s.phase_tick - s.vacuum_starts[i] < s.vacuum_steps[i] do return true
	}
	return false
}

crumble_next :: proc(s: ^Crumble_State, e: ^engine.Engine) -> bool #no_bounds_check {
	for {
		switch s.phase {
		case .Falling:
			if !crumble_falling_active(s) {
				s.phase = .Vacuuming
				s.phase_tick = 0
				continue
			}
			if s.next_fall < len(s.fall_order) {
				if s.fall_delay == 0 {
					count := engine.random_range(1, s.fall_group_size + 1)
					for _ in 0 ..< count {
						if s.next_fall == len(s.fall_order) do break
						i := s.fall_order[s.next_fall]
						s.next_fall += 1
						s.fall_starts[i] = s.phase_tick
						append(&s.fall_active, i)
					}
					s.fall_delay = engine.random_range(s.min_fall_delay, s.max_fall_delay + 1)
					if engine.random_range(1, 11) > 4 {
						s.fall_group_size += 1
						s.min_fall_delay = max(s.min_fall_delay - 1, 0)
						s.max_fall_delay = max(s.max_fall_delay - 1, 0)
					}
				} else {
					s.fall_delay -= 1
				}
			}
			fall_write := 0
			for i in s.fall_active {
				id := s.characters[i]
				start := s.fall_starts[i]
				age := s.phase_tick - start
				if age >= 40 + s.fall_steps[i] do continue
				if age < 40 {
					if age % 4 == 0 {
						engine.set_symbol(e, id, e.particles.initial_symbol[id])
						engine.set_appearance(
							e,
							id,
							engine.ramp_code(s.weak_to_dust_ramp, s.weak_to_dust_index[i], age / 4),
						)
					}
					s.fall_active[fall_write] = i
					fall_write += 1
					continue
				}
				fall_age := age - 40
				progress := f64(min(fall_age + 1, s.fall_steps[i])) / f64(s.fall_steps[i])
				input := s.coords[i]
				engine.set_position(
					e,
					id,
					engine.tween(
						input,
						engine.coord(input.column, e.canvas.bottom),
						ease.ease(.Bounce_Out, progress),
					),
				)
				dust_index := min((fall_age * 5) / s.fall_steps[i], 4)
				engine.set_symbol(e, id, s.dust_symbols[i * 5 + dust_index])
				if fall_age == 0 {
					engine.set_appearance(
						e,
						id,
						engine.ramp_code(s.weak_to_dust_ramp, s.weak_to_dust_index[i], 9),
					)
				}
				s.fall_active[fall_write] = i
				fall_write += 1
			}
			resize(&s.fall_active, fall_write)
			s.phase_tick += 1
			return true

		case .Vacuuming:
			if !crumble_vacuum_active(s) {
				s.phase = .Resetting
				s.phase_tick = 0
				continue
			}
			for _ in 0 ..< engine.random_range(3, 10) {
				if s.next_vacuum == len(s.vacuum_order) do break
				i := s.vacuum_order[s.next_vacuum]
				s.next_vacuum += 1
				s.vacuum_starts[i] = s.phase_tick
				append(&s.vacuum_active, i)
			}
			vacuum_write := 0
			vacuum_control := engine.coord(e.canvas.center_column, e.canvas.center_row)
			for i in s.vacuum_active {
				id := s.characters[i]
				start := s.vacuum_starts[i]
				age := s.phase_tick - start
				steps := s.vacuum_steps[i]
				if age >= steps do continue
				progress := f64(min(age + 1, steps)) / f64(steps)
				input := s.coords[i]
				engine.set_position(
					e,
					id,
					engine.coord_on_quadratic_bezier(
						engine.coord(input.column, e.canvas.bottom),
						vacuum_control,
						engine.coord(input.column, e.canvas.top),
						ease.ease(.Quintic_Out, progress),
					),
				)
				s.vacuum_active[vacuum_write] = i
				vacuum_write += 1
			}
			resize(&s.vacuum_active, vacuum_write)
			s.phase_tick += 1
			return true

		case .Resetting:
			if s.phase_tick == s.reset_max_ticks do return false
			write := 0
			for i in s.reset_active {
				id := s.characters[i]
				input := s.coords[i]
				steps := s.reset_steps[i]
				if s.phase_tick < steps + 64 {
					s.reset_active[write] = i
					write += 1
				}
				if s.phase_tick < steps {
					engine.set_position(
						e,
						id,
						engine.tween(
							engine.coord(input.column, e.canvas.top),
							input,
							f64(s.phase_tick + 1) / f64(steps),
						),
					)
					if s.phase_tick == 0 {
						engine.set_symbol(e, id, e.particles.initial_symbol[id])
						engine.set_appearance(
							e,
							id,
							engine.ramp_code(s.weak_to_dust_ramp, s.weak_to_dust_index[i], 9),
						)
					}
					continue
				}
				flash_age := s.phase_tick - steps
				if flash_age > 64 || flash_age % 4 != 0 do continue
				engine.set_symbol(e, id, e.particles.initial_symbol[id])
				if flash_age < 28 {
					engine.set_appearance(
						e,
						id,
						engine.ramp_code(s.flash_up_ramp, s.flash_up_index[i], flash_age / 4),
					)
				} else {
					engine.set_appearance(
						e,
						id,
						engine.ramp_code(
							s.flash_down_ramp,
							s.flash_down_index[i],
							min((flash_age - 28) / 4, 9),
						),
					)
				}
			}
			resize(&s.reset_active, write)
			s.phase_tick += 1
			return true
		}
	}
}
