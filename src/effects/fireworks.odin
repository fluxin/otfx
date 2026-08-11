package effects

import "../engine"

import "core:fmt"
import "core:math"
import "core:math/ease"
import "core:math/rand"

Fireworks_Config :: struct {
	explode_anywhere:         bool,
	firework_colors:          [dynamic]engine.Color,
	firework_symbol:          string,
	firework_volume:          f64,
	launch_delay:             int,
	explode_distance:         f64,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

fireworks_config_default :: proc() -> Fireworks_Config {
	cfg := Fireworks_Config {
		firework_symbol          = "o",
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
			cfg.explode_anywhere = true
		case "--firework-colors":
			if !parse_colors_flag(&cfg.firework_colors, args, &i, value, has_value) do return false
		case "--firework-symbol":
			if !parse_symbol_flag(&cfg.firework_symbol, args, &i, value, has_value) do return false
		case "--firework-volume":
			if !parse_float_flag(&cfg.firework_volume, args, &i, value, has_value) || cfg.firework_volume < 0 || cfg.firework_volume > 1 do return false
		case "--launch-delay":
			if !parse_int_flag(&cfg.launch_delay, args, &i, value, has_value) || cfg.launch_delay < 0 do return false
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
// holds its own trajectory columns; shells only own launch time and color.
Fireworks_State :: struct {
	config:             Fireworks_Config,
	characters:         [dynamic]engine.Char_Id,
	final_colors:       [dynamic]engine.Color,
	shell_index:        [dynamic]int,
	shell_offsets:      [dynamic]int,
	shell_origins:      [dynamic]engine.Coord,
	shell_colors:       [dynamic]engine.Color,
	shell_start_ticks:  [dynamic]int,
	// This belongs to the shell, not each particle. It avoids deriving the
	// launch scene's three-frame color cycle in the dense particle loop.
	shell_launch_phase: [dynamic]u8,
	apex_steps:         [dynamic]int,
	explode_steps:      [dynamic]int,
	bloom_steps:        [dynamic]int,
	fall_steps:         [dynamic]int,
	explode_targets:    [dynamic]engine.Coord,
	bloom_controls:     [dynamic]engine.Coord,
	bloom_targets:      [dynamic]engine.Coord,
	next_shell:         int,
	launch_delay:       int,
	tick:               int,
}

// Pick directly from TerminalTextEffects' filled terminal-aspect ellipse.
// The reference materializes this list then chooses an entry; summing its
// column spans first gives the same distribution without a temporary array.
fireworks_random_explode_target :: proc(origin: engine.Coord, diameter: int) -> engine.Coord {
	a_squared := math.pow(f64(diameter), 2)
	b_squared := math.pow(f64(diameter) / 2, 2)
	count := 0
	for column in origin.column - diameter ..= origin.column + diameter {
		x := f64(column - origin.column)
		row_offset := int(math.sqrt(b_squared * (1 - math.pow(x, 2) / a_squared)))
		count += row_offset * 2 + 1
	}
	entry := rand.int_max(count)
	for column in origin.column - diameter ..= origin.column + diameter {
		x := f64(column - origin.column)
		row_offset := int(math.sqrt(b_squared * (1 - math.pow(x, 2) / a_squared)))
		span := row_offset * 2 + 1
		if entry < span do return engine.coord(column, origin.row - row_offset + entry)
		entry -= span
	}
	panic("fireworks explode target selection exhausted")
}

fireworks_build :: proc(s: ^Fireworks_State, e: ^engine.Engine) {
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
	s.final_colors = make([dynamic]engine.Color, n)
	s.shell_index = make([dynamic]int, n)
	s.apex_steps = make([dynamic]int, n)
	s.explode_steps = make([dynamic]int, n)
	s.bloom_steps = make([dynamic]int, n)
	s.fall_steps = make([dynamic]int, n)
	s.explode_targets = make([dynamic]engine.Coord, n)
	s.bloom_controls = make([dynamic]engine.Coord, n)
	s.bloom_targets = make([dynamic]engine.Coord, n)

	// A one-character "shell" has no visible burst. Keep the configured ratio
	// for normal-sized input, but make the default effect a firework even for a
	// short command-line sample.
	volume := clamp(max(engine.round_half_even(s.config.firework_volume * f64(n)), 8), 1, n)
	for start := 0; start < n; start += volume do append(&s.shell_offsets, start)
	append(&s.shell_offsets, n)
	shell_count := len(s.shell_offsets) - 1
	s.shell_origins = make([dynamic]engine.Coord, shell_count)
	s.shell_colors = make([dynamic]engine.Color, shell_count)
	s.shell_start_ticks = make([dynamic]int, shell_count)
	s.shell_launch_phase = make([dynamic]u8, shell_count)
	for i in 0 ..< shell_count do s.shell_start_ticks[i] = -1

	explode_distance := clamp(
		engine.round_half_even(f64(e.canvas.right) * s.config.explode_distance),
		1,
		15,
	)
	input_coords := e.chars.input_coord
	visible := e.chars.is_visible
	for shell in 0 ..< shell_count {
		first := s.shell_offsets[shell]
		min_row :=
			s.config.explode_anywhere ? e.canvas.bottom : input_coords[s.characters[first]].row
		origin := engine.coord(
			rand.int_range(e.canvas.left, e.canvas.right + 1),
			rand.int_range(min_row, e.canvas.top + 1),
		)
		s.shell_origins[shell] = origin
		s.shell_colors[shell] =
			s.config.firework_colors[rand.int_max(len(s.config.firework_colors))]
		for i in s.shell_offsets[shell] ..< s.shell_offsets[shell + 1] {
			id := s.characters[i]
			input := input_coords[id]
			s.shell_index[i] = shell
			s.final_colors[i] = engine.gradient_sample(sampler, spectrum[:], input)
			visible[id] = false
			launch := engine.coord(origin.column, e.canvas.bottom)
			s.apex_steps[i] = max(
				engine.round_half_even(engine.line_length(launch, origin, true) / 0.35),
				1,
			)

			explode := fireworks_random_explode_target(origin, explode_distance)
			s.explode_targets[i] = explode
			explode_speed := rand.float64_range(0.2, 0.4)
			s.explode_steps[i] = max(
				engine.round_half_even(engine.line_length(origin, explode, true) / explode_speed),
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
				engine.round_half_even(
					engine.quadratic_bezier_length(explode, control, bloom) / explode_speed,
				),
				1,
			)
			fall_control := engine.coord(bloom.column, 1)
			s.fall_steps[i] = max(
				engine.round_half_even(
					engine.quadratic_bezier_length(bloom, fall_control, input) / 0.6,
				),
				1,
			)
		}
	}
	s.next_shell = shell_count - 1
}

fireworks_next :: proc(s: ^Fireworks_State, e: ^engine.Engine) -> ([]engine.Char_Id, bool) {
	active := s.next_shell >= 0
	if !active {
		for _, i in s.characters {
			shell := s.shell_index[i]
			start := s.shell_start_ticks[shell]
			if start < 0 do continue
			fall_time := max(s.fall_steps[i], 160)
			if s.tick - start <
			   s.apex_steps[i] + s.explode_steps[i] + s.bloom_steps[i] + fall_time {
				active = true
				break
			}
		}
	}
	if !active do return nil, false

	if s.next_shell >= 0 && s.launch_delay <= 0 {
		shell := s.next_shell
		s.shell_start_ticks[shell] = s.tick
		s.shell_launch_phase[shell] = 0
		s.next_shell -= 1
		s.launch_delay = engine.round_half_even(
			f64(s.config.launch_delay) * rand.float64_range(0.5, 1.5),
		)
	}
	s.launch_delay -= 1

	input_coords := e.chars.input_coord
	current_coords := e.chars.current_coord
	input_symbols := e.chars.input_symbol
	visual_symbols := e.chars.visual
	visual_fg := e.chars.visual
	visible := e.chars.is_visible
	launch_phases := s.shell_launch_phase
	for id, i in s.characters {
		shell := s.shell_index[i]
		start := s.shell_start_ticks[shell]
		if start < 0 do continue
		age := s.tick - start
		origin := s.shell_origins[shell]
		color := s.shell_colors[shell]
		launch := engine.coord(origin.column, e.canvas.bottom)
		apex_end := s.apex_steps[i]
		explode_steps := s.explode_steps[i]
		bloom_steps := s.bloom_steps[i]
		explode_end := apex_end + explode_steps
		bloom_end := explode_end + bloom_steps
		visible[id] = true
		e.chars.layer[id] = 2
		if age < apex_end {
			current_coords[id] = engine.coord_on_line(
				launch,
				origin,
				ease.ease(.Exponential_Out, f64(age + 1) / f64(s.apex_steps[i])),
			)
			visual_symbols[id].symbol = s.config.firework_symbol
			visual_fg[id].fg = launch_phases[shell] == 2 ? engine.Color{0xFF, 0xFF, 0xFF} : color
		} else if age < explode_end {
			move_age := age - apex_end
			current_coords[id] = engine.coord_on_line(
				origin,
				s.explode_targets[i],
				ease.ease(.Circular_Out, f64(move_age + 1) / f64(explode_steps)),
			)
			// Rust activates the step-synced bloom scene as soon as the apex
			// finishes. Its 11 colors are each held for two scene frames.
			// Sample that 22-frame stream over both outgoing path segments.
			gradient_frames :: 22
			path_steps := explode_steps + bloom_steps
			frame_index := clamp(
				engine.round_half_even(
					f64(gradient_frames - 1) * f64(move_age + 1) / f64(path_steps),
				),
				0,
				gradient_frames - 1,
			)
			gradient_step := math.floor_div(frame_index, 2)
			visual_symbols[id].symbol = input_symbols[id]
			if gradient_step <= 5 {
				visual_fg[id].fg = engine.gradient_between_step(
					color,
					engine.Color{0xFF, 0xFF, 0xFF},
					5,
					gradient_step,
				)
			} else {
				visual_fg[id].fg = engine.gradient_between_step(
					engine.Color{0xFF, 0xFF, 0xFF},
					color,
					5,
					gradient_step - 5,
				)
			}
		} else if age < bloom_end {
			move_age := age - explode_end
			current_coords[id] = engine.coord_on_quadratic_bezier(
				s.explode_targets[i],
				s.bloom_controls[i],
				s.bloom_targets[i],
				ease.ease(.Circular_Out, f64(move_age + 1) / f64(bloom_steps)),
			)
			gradient_frames :: 22
			path_steps := explode_steps + bloom_steps
			frame_index := clamp(
				engine.round_half_even(
					f64(gradient_frames - 1) * f64(explode_steps + move_age + 1) / f64(path_steps),
				),
				0,
				gradient_frames - 1,
			)
			entry := math.floor_div(frame_index, 2)
			visual_symbols[id].symbol = input_symbols[id]
			if entry <= 5 {
				visual_fg[id].fg = engine.gradient_between_step(
					color,
					engine.Color{0xFF, 0xFF, 0xFF},
					5,
					entry,
				)
			} else {
				visual_fg[id].fg = engine.gradient_between_step(
					engine.Color{0xFF, 0xFF, 0xFF},
					color,
					5,
					entry - 5,
				)
			}
		} else {
			fall_age := age - bloom_end
			input := input_coords[id]
			if fall_age < s.fall_steps[i] {
				current_coords[id] = engine.coord_on_quadratic_bezier(
					s.bloom_targets[i],
					engine.coord(s.bloom_targets[i].column, 1),
					input,
					ease.ease(.Quartic_In_Out, f64(fall_age + 1) / f64(s.fall_steps[i])),
				)
			}
			visual_symbols[id].symbol = input_symbols[id]
			visual_fg[id].fg = engine.gradient_between_step(
				color,
				s.final_colors[i],
				15,
				min(fall_age / 10, 15),
			)
		}
	}
	for shell in 0 ..< len(launch_phases) {
		if s.shell_start_ticks[shell] < 0 do continue
		phase := launch_phases[shell] + 1
		launch_phases[shell] = phase == 3 ? 0 : phase
	}
	s.tick += 1
	return s.characters[:], true
}
