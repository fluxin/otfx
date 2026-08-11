package effects

import engine "../engine"

import "core:fmt"
import ease "core:math/ease"
import rand "core:math/rand"

Unstable_Config :: struct {
	unstable_color:           engine.Color,
	explosion_ease:           ease.Ease,
	explosion_speed:          f64,
	reassembly_ease:          ease.Ease,
	reassembly_speed:         f64,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

unstable_config_default :: proc() -> Unstable_Config {
	cfg := Unstable_Config {
		unstable_color           = engine.Color{0xff, 0x92, 0x00},
		explosion_ease           = .Exponential_Out,
		explosion_speed          = 1,
		reassembly_ease          = .Exponential_Out,
		reassembly_speed         = 1,
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

unstable_parse :: proc(cfg: ^Unstable_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--unstable-color":
			if !parse_color_flag(&cfg.unstable_color, args, &i, value, has_value) do return false
		case "--explosion-ease":
			if !parse_ease_flag(&cfg.explosion_ease, args, &i, value, has_value) do return false
		case "--explosion-speed":
			if !parse_float_flag(&cfg.explosion_speed, args, &i, value, has_value) || cfg.explosion_speed <= 0 do return false
		case "--reassembly-ease":
			if !parse_ease_flag(&cfg.reassembly_ease, args, &i, value, has_value) do return false
		case "--reassembly-speed":
			if !parse_float_flag(&cfg.reassembly_speed, args, &i, value, has_value) || cfg.reassembly_speed <= 0 do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown unstable option: ", name)
			return false
		}
	}
	return true
}

Unstable_Phase :: enum {
	Rumble,
	Explosion,
	Explosion_Hold,
	Reassembly,
}

// Every row is parallel to characters. The effect used to create two Paths
// and two Scenes per character; it now evaluates the two one-segment motions
// and color ramps directly from these dense columns.
Unstable_State :: struct {
	config:               Unstable_Config,
	characters:           [dynamic]engine.Char_Id,
	jumbled_coords:       [dynamic]engine.Coord,
	explosion_targets:    [dynamic]engine.Coord,
	final_colors:         [dynamic]engine.Color,
	explosion_steps:      [dynamic]int,
	reassembly_steps:     [dynamic]int,
	phase:                Unstable_Phase,
	phase_tick:           int,
	explosion_max_steps:  int,
	reassembly_max_steps: int,
	rumble_delay:         int,
}

unstable_build :: proc(s: ^Unstable_State, e: ^engine.Engine) {
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

	s.characters = engine.get_characters(
		engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas},
		engine.filter_input(),
		.Top_Bottom_Left_Right,
	)
	n := len(s.characters)
	s.jumbled_coords = make([dynamic]engine.Coord, n)
	s.explosion_targets = make([dynamic]engine.Coord, n)
	s.final_colors = make([dynamic]engine.Color, n)
	s.explosion_steps = make([dynamic]int, n)
	s.reassembly_steps = make([dynamic]int, n)

	// This is a bounded temporary permutation of input locations. Its order has
	// no semantic meaning, so unordered removal keeps the shuffle O(n).
	available := make([dynamic]engine.Coord, n, context.temp_allocator)
	input_coords := e.chars.input_coord
	for id, i in s.characters do available[i] = input_coords[id]

	current_coords := e.chars.current_coord
	visible := e.chars.is_visible
	visual_fg := e.chars.visual_fg
	for id, i in s.characters {
		edge := rand.int_max(4)
		target: engine.Coord
		switch edge {
		case 0:
			target = engine.coord(e.canvas.left, engine.canvas_random_row(e.canvas, false))
		case 1:
			target = engine.coord(e.canvas.right, engine.canvas_random_row(e.canvas, false))
		case 2:
			target = engine.coord(engine.canvas_random_column(e.canvas, false), e.canvas.bottom)
		case:
			target = engine.coord(engine.canvas_random_column(e.canvas, false), e.canvas.top)
		}
		coord_index := rand.int_max(len(available))
		jumbled := available[coord_index]
		unordered_remove(&available, coord_index)

		final_color := engine.gradient_sample(sampler, spectrum[:], input_coords[id])
		s.jumbled_coords[i] = jumbled
		s.explosion_targets[i] = target
		s.final_colors[i] = final_color
		s.explosion_steps[i] = max(
			engine.round_half_even(
				engine.line_length(jumbled, target, true) / s.config.explosion_speed,
			),
			1,
		)
		s.reassembly_steps[i] = max(
			engine.round_half_even(
				engine.line_length(target, input_coords[id], true) / s.config.reassembly_speed,
			),
			1,
		)
		s.explosion_max_steps = max(s.explosion_max_steps, s.explosion_steps[i])
		s.reassembly_max_steps = max(s.reassembly_max_steps, s.reassembly_steps[i])
		current_coords[id] = jumbled
		visual_fg[id] = final_color
		visible[id] = true
	}
	s.phase = .Rumble
	s.rumble_delay = 18
}

unstable_next :: proc(s: ^Unstable_State, e: ^engine.Engine) -> bool {
	input_coords := e.chars.input_coord
	current_coords := e.chars.current_coord
	visual_fg := e.chars.visual_fg

	for {
		switch s.phase {
		case .Rumble:
			if s.phase_tick == 150 {
				s.phase = .Explosion
				s.phase_tick = 0
				continue
			}
			color_step := min(s.phase_tick / 10, 12)
			for id, i in s.characters {
				visual_fg[id] = engine.gradient_between_step(
					s.final_colors[i],
					s.config.unstable_color,
					12,
					color_step,
				)
			}
			jitter := s.phase_tick > 30 && s.phase_tick % s.rumble_delay == 0
			if jitter {
				row_offset := rand.int_range(-1, 2)
				column_offset := rand.int_range(-1, 2)
				for id, i in s.characters {
					p := s.jumbled_coords[i]
					current_coords[id] = engine.coord(p.column + column_offset, p.row + row_offset)
				}
			}
			engine.frame(e, s.characters[:])
			if jitter {
				for id, i in s.characters do current_coords[id] = s.jumbled_coords[i]
				s.rumble_delay = max(s.rumble_delay - 1, 1)
			}
			s.phase_tick += 1
			return true

		case .Explosion:
			if s.phase_tick == s.explosion_max_steps {
				s.phase = .Explosion_Hold
				s.phase_tick = 0
				continue
			}
			for id, i in s.characters {
				steps := s.explosion_steps[i]
				progress := f64(min(s.phase_tick + 1, steps)) / f64(steps)
				current_coords[id] = engine.coord_on_line(
					s.jumbled_coords[i],
					s.explosion_targets[i],
					ease.ease(s.config.explosion_ease, progress),
				)
			}
			engine.frame(e, s.characters[:])
			s.phase_tick += 1
			return true

		case .Explosion_Hold:
			if s.phase_tick == 30 {
				s.phase = .Reassembly
				s.phase_tick = 0
				continue
			}
			engine.frame(e, s.characters[:])
			s.phase_tick += 1
			return true

		case .Reassembly:
			// 13 gradient entries at three frames each. Motion and color settle
			// together, exactly as the old path + scene combination did.
			final_ticks := max(s.reassembly_max_steps, 39)
			if s.phase_tick == final_ticks do return false
			color_step := min(s.phase_tick / 3, 12)
			for id, i in s.characters {
				steps := s.reassembly_steps[i]
				progress := f64(min(s.phase_tick + 1, steps)) / f64(steps)
				current_coords[id] = engine.coord_on_line(
					s.explosion_targets[i],
					input_coords[id],
					ease.ease(s.config.reassembly_ease, progress),
				)
				visual_fg[id] = engine.gradient_between_step(
					s.config.unstable_color,
					s.final_colors[i],
					12,
					color_step,
				)
			}
			engine.frame(e, s.characters[:])
			s.phase_tick += 1
			return true
		}
	}
}
