package effects

import "../engine"

import "core:fmt"
import "core:math"
import "core:math/ease"

Fireworks_Config :: struct {
	explode_anywhere:         bool,
	firework_colors:          [dynamic]engine.Color,
	firework_symbol:          rune,
	firework_volume:          f64,
	launch_delay:             int,
	explode_distance:         f64,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

fireworks_config_default :: proc() -> Fireworks_Config {
	cfg := Fireworks_Config {
		firework_symbol          = 'o',
		firework_volume          = 0.05,
		launch_delay             = 45,
		explode_distance         = 0.2,
		final_gradient_direction = .Horizontal,
	}
	append(
		&cfg.firework_colors,
		..[]engine.Color {
			engine.Color{0x88, 0xF7, 0xE2},
			engine.Color{0x44, 0xD4, 0x92},
			engine.Color{0xF5, 0xEB, 0x67},
			engine.Color{0xFF, 0xA1, 0x5C},
			engine.Color{0xFA, 0x23, 0x3E},
		},
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

fireworks_parse :: proc(cfg: ^Fireworks_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--explode-anywhere":
			if !parse_bool_flag(&cfg.explode_anywhere, has_value) do return false
		case "--firework-colors":
			if !parse_colors_flag(&cfg.firework_colors, args, &i, value, has_value) do return false
		case "--firework-symbol":
			if !parse_symbol_flag(&cfg.firework_symbol, args, &i, value, has_value) do return false
		case "--firework-volume":
			if !parse_float_flag(&cfg.firework_volume, args, &i, value, has_value) || cfg.firework_volume < 0 || cfg.firework_volume > 1 do return false
		case "--launch-delay":
			if !parse_int_flag(&cfg.launch_delay, args, &i, value, has_value, minimum = 0) || cfg.launch_delay < 0 do return false
		case "--explode-distance":
			if !parse_float_flag(&cfg.explode_distance, args, &i, value, has_value) || cfg.explode_distance < 0 || cfg.explode_distance > 1 do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown fireworks option: ", name)
			return false
		}
	}
	return true
}

// Shell membership is one flat character array plus offsets. Every character
// holds its own burst/return trajectory; shells own their shared launch motion.
Fireworks_State :: struct {
	config:            Fireworks_Config,
	characters:        [dynamic]engine.Particle_Id,
	targets:           [dynamic]engine.Coord,
	fall_ramp:         engine.Appearance_Ramp,
	fall_index:        [dynamic]int,
	color_steps:       [dynamic]u8, // last burst/fall sample; each phase publishes on entry
	active_indexes:    [dynamic]int,
	first_active:      int, // unlaunched shells occupy the untouched prefix
	finish_ages:       [dynamic]int,
	shell_index:       [dynamic]int,
	shell_offsets:     [dynamic]int,
	shell_origins:     [dynamic]engine.Coord,
	shell_positions:   [dynamic]engine.Coord,
	shell_codes:       [dynamic]engine.Appearance_Id,
	shell_bloom_codes: [dynamic][11]engine.Appearance_Id,
	white_code:        engine.Appearance_Id,
	shell_start_ticks: [dynamic]int,
	// This belongs to the shell, not each particle. It avoids deriving the
	// launch scene's three-frame color cycle in the dense particle loop.
	shell_launch_phase: [dynamic]u8,
	apex_steps:        [dynamic]int,
	explode_steps:     [dynamic]int,
	bloom_steps:       [dynamic]int,
	fall_steps:        [dynamic]int,
	explode_targets:   [dynamic]engine.Coord,
	bloom_controls:    [dynamic]engine.Coord,
	bloom_targets:     [dynamic]engine.Coord,
	next_shell:        int,
	launch_delay:      int,
	tick:              int,
	color_handling:    engine.Existing_Color_Handling,
}

// Pick directly from TerminalTextEffects' filled terminal-aspect ellipse.
// `diameter` is bounded by 15 (`2 * diameter + 1 <= 31`), so caching the row
// offsets in a tiny stack array avoids repeating `sqrt` in a second pass.
fireworks_random_explode_target :: proc(origin: engine.Coord, diameter: int) -> engine.Coord #no_bounds_check {
	d := f64(diameter)
	a_squared := d * d
	half_d := d * 0.5
	b_squared := half_d * half_d
	row_offsets: [31]int
	span_count := diameter * 2 + 1
	count := 0
	for idx in 0 ..< span_count {
		x := f64(idx - diameter)
		row_offset := int(math.sqrt(b_squared * (1.0 - (x * x) / a_squared)))
		row_offsets[idx] = row_offset
		count += row_offset * 2 + 1
	}
	entry := engine.random_below(count)
	for idx in 0 ..< span_count {
		row_offset := row_offsets[idx]
		span := row_offset * 2 + 1
		if entry < span do return engine.coord(origin.column - diameter + idx, origin.row - row_offset + entry)
		entry -= span
	}
	panic("fireworks explode target selection exhausted")
}

fireworks_build :: proc(s: ^Fireworks_State, e: ^engine.Engine) {
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
	if n == 0 {
		s.next_shell = -1
		return
	}
	s.targets = make([dynamic]engine.Coord, n)
	s.color_steps = make([dynamic]u8, n)
	s.active_indexes = make([dynamic]int, n)
	for i in 0 ..< n do s.active_indexes[i] = i
	s.first_active = n
	s.finish_ages = make([dynamic]int, n)
	s.shell_index = make([dynamic]int, n)
	s.explode_steps = make([dynamic]int, n)
	s.bloom_steps = make([dynamic]int, n)
	s.fall_steps = make([dynamic]int, n)
	s.explode_targets = make([dynamic]engine.Coord, n)
	s.bloom_controls = make([dynamic]engine.Coord, n)
	s.bloom_targets = make([dynamic]engine.Coord, n)

	// A one-character "shell" has no visible burst. Keep the configured ratio
	// for normal-sized input, but make the default effect a firework even for a
	// short command-line sample.
	volume := clamp(max(engine.round_to_int(s.config.firework_volume * f64(n)), 8), 1, n)
	for start := 0; start < n; start += volume do append(&s.shell_offsets, start)
	append(&s.shell_offsets, n)
	shell_count := len(s.shell_offsets) - 1
	s.shell_origins = make([dynamic]engine.Coord, shell_count)
	s.shell_positions = make([dynamic]engine.Coord, shell_count)
	s.apex_steps = make([dynamic]int, shell_count)
	s.shell_codes = make([dynamic]engine.Appearance_Id, shell_count)
	s.shell_bloom_codes = make([dynamic][11]engine.Appearance_Id, shell_count)
	s.shell_start_ticks = make([dynamic]int, shell_count)
	s.shell_launch_phase = make([dynamic]u8, shell_count)
	for i in 0 ..< shell_count do s.shell_start_ticks[i] = -1

	white := engine.Color{0xFF, 0xFF, 0xFF}
	s.white_code = engine.prepare_appearance(e, {colors = {fg = white}})

	// Precompute unique bloom palettes per configured firework color.
	palette_len := len(s.config.firework_colors)
	palette_shell_codes := make([]engine.Appearance_Id, palette_len, context.temp_allocator)
	palette_bloom_codes := make([][11]engine.Appearance_Id, palette_len, context.temp_allocator)
	defer delete(palette_shell_codes, context.temp_allocator)
	defer delete(palette_bloom_codes, context.temp_allocator)
	for fw_color, ci in s.config.firework_colors {
		base_code := fw_color == white ? s.white_code : engine.prepare_appearance(e, {colors = {fg = fw_color}})
		palette_shell_codes[ci] = base_code
		palette_bloom_codes[ci][0] = base_code
		palette_bloom_codes[ci][5] = s.white_code
		palette_bloom_codes[ci][10] = base_code
		for step in 1 ..= 4 {
			c := engine.tween(fw_color, white, 5, step)
			code := engine.prepare_appearance(e, {colors = {fg = c}})
			palette_bloom_codes[ci][step] = code
			palette_bloom_codes[ci][10 - step] = code
		}
	}

	fall_tweens := make([]engine.Tween(engine.Appearance), n, context.temp_allocator)
	defer delete(fall_tweens, context.temp_allocator)

	explode_distance := clamp(
		engine.round_to_int(f64(e.canvas.right) * s.config.explode_distance),
		1,
		15,
	)
	initial_coords := e.particles.initial_coord
	visible_flags := e.particles.flags
	for shell in 0 ..< shell_count {
		first := s.shell_offsets[shell]
		min_row :=
			s.config.explode_anywhere ? e.canvas.bottom : initial_coords[s.characters[first]].row
		origin := engine.coord(
			engine.random_range(e.canvas.left, e.canvas.right + 1),
			engine.random_range(min_row, e.canvas.top + 1),
		)
		s.shell_origins[shell] = origin
		launch := engine.coord(origin.column, e.canvas.bottom)
		s.apex_steps[shell] = max(
			engine.round_to_int(engine.line_length(launch, origin, true) / 0.35),
			1,
		)
		ci := engine.random_below(palette_len)
		shell_color := s.config.firework_colors[ci]
		s.shell_codes[shell] = palette_shell_codes[ci]
		s.shell_bloom_codes[shell] = palette_bloom_codes[ci]
		for i in s.shell_offsets[shell] ..< s.shell_offsets[shell + 1] {
			id := s.characters[i]
			input := initial_coords[id]
			s.targets[i] = input
			s.shell_index[i] = shell
			initial := engine.get_initial_appearance(e, id)
			if s.color_handling == .Dynamic {
				fall_tweens[i] = {
					from = {colors = {shell_color, shell_color}},
					to   = {colors = initial.colors},
				}
			} else {
				final_color := engine.gradient_sample(sampler, spectrum[:], input)
				fall_tweens[i] = {
					from = {colors = {fg = shell_color}},
					to   = {colors = {fg = final_color}},
				}
			}
			visible_flags[id] -= {.Visible}

			explode := fireworks_random_explode_target(origin, explode_distance)
			s.explode_targets[i] = explode
			explode_speed := engine.random_float_range(0.2, 0.4)
			s.explode_steps[i] = max(
				engine.round_to_int(engine.line_length(origin, explode, true) / explode_speed),
				1,
			)
			control := engine.extrapolate_along_ray(
				origin,
				explode,
				f64(math.floor_div(explode_distance, 2)),
			)
			bloom := engine.coord(control.column, max(1, control.row - 7))
			s.bloom_controls[i] = control
			s.bloom_targets[i] = bloom
			s.bloom_steps[i] = max(
				engine.round_to_int(
					engine.quadratic_bezier_length(explode, control, bloom) / explode_speed,
				),
				1,
			)
			fall_control := engine.coord(bloom.column, 1)
			s.fall_steps[i] = max(
				engine.round_to_int(
					engine.quadratic_bezier_length(bloom, fall_control, input) / 0.6,
				),
				1,
			)
			color_ticks :=
				s.color_handling == .Dynamic && initial.colors.fg == nil && initial.colors.bg == nil ? 10 : 160
			s.finish_ages[i] =
				s.apex_steps[shell] +
				s.explode_steps[i] +
				s.bloom_steps[i] +
				max(s.fall_steps[i], color_ticks)
		}
	}
	unique_tweens: [dynamic]engine.Tween(engine.Appearance)
	unique_tweens, s.fall_index = engine.group_values(fall_tweens)
	defer delete(unique_tweens)
	s.fall_ramp = engine.ramp_make(e, unique_tweens[:], 15)

	s.next_shell = shell_count - 1
}

fireworks_next :: proc(s: ^Fireworks_State, e: ^engine.Engine) -> bool #no_bounds_check {
	if s.next_shell < 0 && len(s.active_indexes) == s.first_active do return false

	if s.next_shell >= 0 && s.launch_delay <= 0 {
		shell := s.next_shell
		s.shell_start_ticks[shell] = s.tick
		s.first_active = s.shell_offsets[shell]
		s.shell_launch_phase[shell] = 0
		s.next_shell -= 1
		s.launch_delay = engine.round_to_int(
			f64(s.config.launch_delay) * engine.random_float_range(0.5, 1.5),
		)
	}
	s.launch_delay -= 1

	for start, shell in s.shell_start_ticks {
		age := s.tick - start
		if start < 0 || age >= s.apex_steps[shell] do continue
		origin := s.shell_origins[shell]
		s.shell_positions[shell] = engine.tween(
			engine.coord(origin.column, e.canvas.bottom),
			origin,
			ease.ease(.Exponential_Out, f64(age + 1) / f64(s.apex_steps[shell])),
		)
	}
	launch_phases := s.shell_launch_phase
	write := s.first_active
	for i in s.active_indexes[s.first_active:] {
		id := s.characters[i]
		shell := s.shell_index[i]
		start := s.shell_start_ticks[shell]
		age := s.tick - start
		origin := s.shell_origins[shell]
		apex_end := s.apex_steps[shell]
		explode_steps := s.explode_steps[i]
		bloom_steps := s.bloom_steps[i]
		bloom_end := apex_end + explode_steps + bloom_steps
		position: engine.Coord
		moving := true
		if age < apex_end {
			position = s.shell_positions[shell]
			if age == 0 do engine.set_symbol(e, id, s.config.firework_symbol)
			// The launch sequence holds its shell color for two frames, then white.
			if launch_phases[shell] != 1 {
				engine.set_appearance(
					e,
					id,
					launch_phases[shell] == 2 ? s.white_code : s.shell_codes[shell],
				)
			}
		} else if age < bloom_end {
			move_age := age - apex_end
			if move_age == 0 do engine.set_symbol(e, id, e.particles.initial_symbol[id])
			if move_age < explode_steps {
				position = engine.tween(
					origin,
					s.explode_targets[i],
					ease.ease(.Circular_Out, f64(move_age + 1) / f64(explode_steps)),
				)
			} else {
				position = engine.coord_on_quadratic_bezier(
					s.explode_targets[i],
					s.bloom_controls[i],
					s.bloom_targets[i],
					ease.ease(.Circular_Out, f64(move_age - explode_steps + 1) / f64(bloom_steps)),
				)
			}
			// Rust activates the step-synced bloom scene as soon as the apex
			// finishes. Its 11 colors are each held for two scene frames.
			// Sample that 22-frame stream over both outgoing path segments.
			gradient_frames :: 22
			path_steps := explode_steps + bloom_steps
			frame_index := clamp(
				engine.round_to_int(
					f64(gradient_frames - 1) * f64(move_age + 1) / f64(path_steps),
				),
				0,
				gradient_frames - 1,
			)
			gradient_step := math.floor_div(frame_index, 2)
			if move_age == 0 || u8(gradient_step) != s.color_steps[i] {
				s.color_steps[i] = u8(gradient_step)
				engine.set_appearance(e, id, s.shell_bloom_codes[shell][gradient_step])
			}
		} else {
			fall_age := age - bloom_end
			if fall_age < s.fall_steps[i] {
				position = engine.coord_on_quadratic_bezier(
					s.bloom_targets[i],
					engine.coord(s.bloom_targets[i].column, 1),
					s.targets[i],
					ease.ease(.Quartic_In_Out, f64(fall_age + 1) / f64(s.fall_steps[i])),
				)
			} else {
				moving = false
			}
			step := min(fall_age / 10, 15)
			if fall_age == 0 || u8(step) != s.color_steps[i] {
				s.color_steps[i] = u8(step)
				engine.set_appearance(e, id, engine.ramp_code(s.fall_ramp, s.fall_index[i], step))
			}
		}
		if age == 0 {
			engine.set_placement(e, id, position, true, 2)
		} else if moving {
			engine.set_position(e, id, position)
		}
		if age + 1 < s.finish_ages[i] {
			s.active_indexes[write] = i
			write += 1
		}
	}
	resize(&s.active_indexes, write)
	for shell in 0 ..< len(launch_phases) {
		if s.shell_start_ticks[shell] < 0 do continue
		phase := launch_phases[shell] + 1
		launch_phases[shell] = phase == 3 ? 0 : phase
	}
	s.tick += 1
	return true
}
