package effects

import engine "../engine"

import "core:fmt"
import "core:math"
import ease "core:math/ease"
import rand "core:math/rand"

Blackhole_Config :: struct {
	blackhole_color:          engine.Color,
	star_colors:              [dynamic]engine.Color,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

blackhole_config_default :: proc() -> Blackhole_Config {
	cfg := Blackhole_Config {
		blackhole_color          = engine.Color{0xFF, 0xFF, 0xFF},
		final_gradient_direction = .Diagonal,
	}
	append(
		&cfg.star_colors,
		..[]engine.Color {
			engine.Color{0xFF, 0xCC, 0x0D},
			engine.Color{0xFF, 0x73, 0x26},
			engine.Color{0xFF, 0x19, 0x4D},
			engine.Color{0xBF, 0x26, 0x69},
			engine.Color{0x70, 0x2A, 0x8C},
			engine.Color{0x04, 0x9D, 0xBF},
		},
	)
	append(
		&cfg.final_gradient_stops,
		engine.Color{0x8A, 0x00, 0x8A},
		engine.Color{0x00, 0xD1, 0xFF},
		engine.Color{0xFF, 0xFF, 0xFF},
	)
	append(&cfg.final_gradient_steps, 9)
	return cfg
}

blackhole_parse :: proc(cfg: ^Blackhole_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--blackhole-color":
			if !parse_color_flag(&cfg.blackhole_color, args, &i, value, has_value) do return false
		case "--star-colors":
			if !parse_colors_flag(&cfg.star_colors, args, &i, value, has_value) do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown blackhole option: ", name)
			return false
		}
	}
	return true
}

Blackhole_Phase :: enum {
	Forming,
	Consuming,
	Collapsing,
	Exploding,
}

Blackhole_Star_Symbols :: [7]string{"*", "'", "`", "¤", "•", "°", "·"}

// Ring membership is a dense source-index column; ring source indices and
// circle positions are compact slices. There is no set, map, path, scene, or
// per-character event graph in the frame loop.
Blackhole_State :: struct {
	config:              Blackhole_Config,
	characters:          [dynamic]engine.Char_Id,
	final_colors:        [dynamic]engine.Color,
	star_colors:         [dynamic]engine.Color,
	star_symbols:        [dynamic]string,
	star_coords:         [dynamic]engine.Coord,
	consume_steps:       [dynamic]int,
	ring_slot_by_source: [dynamic]int,
	ring_sources:        [dynamic]int,
	ring_positions:      [dynamic]engine.Coord,
	expanded_positions:  [dynamic]engine.Coord,
	ring_starts:         [dynamic]int,
	ring_steps:          [dynamic]int,
	ring_colors:         [dynamic]engine.Color,
	explode_targets:     [dynamic]engine.Coord,
	explode_steps:       [dynamic]int,
	return_steps:        [dynamic]int,
	explode_colors:      [dynamic]engine.Color,
	radius:              int,
	next_ring:           int,
	formation_delay:     int,
	delay:               int,
	rotation:            int,
	phase:               Blackhole_Phase,
	phase_tick:          int,
	explode_limit:       int,
}

blackhole_ring_position :: #force_inline proc(s: ^Blackhole_State, slot: int) -> engine.Coord {
	index := slot + s.rotation
	if index >= len(s.ring_positions) do index -= len(s.ring_positions)
	return s.ring_positions[index]
}

blackhole_build :: proc(s: ^Blackhole_State, e: ^engine.Engine) {
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
	s.star_colors = make([dynamic]engine.Color, n)
	s.star_symbols = make([dynamic]string, n)
	s.star_coords = make([dynamic]engine.Coord, n)
	s.consume_steps = make([dynamic]int, n)
	s.ring_slot_by_source = make([dynamic]int, n)
	s.explode_targets = make([dynamic]engine.Coord, n)
	s.explode_steps = make([dynamic]int, n)
	s.return_steps = make([dynamic]int, n)
	s.explode_colors = make([dynamic]engine.Color, n)
	for i in 0 ..< n do s.ring_slot_by_source[i] = -1

	s.radius = max(
		min(
			engine.round_half_even(f64(e.canvas.width) * 0.3),
			engine.round_half_even(f64(e.canvas.height) * 0.2),
		),
		3,
	)
	ring_count := min(s.radius * 3, n)
	s.ring_positions = engine.find_coords_on_circle(e.canvas.center, s.radius, ring_count, true)
	// Unique terminal-cell positions can reduce the geometric ring below its
	// requested count; keep membership exactly aligned with available positions.
	ring_count = len(s.ring_positions)
	s.expanded_positions = engine.find_coords_on_circle(
		e.canvas.center,
		s.radius + 3,
		ring_count,
		true,
	)

	input_coords := e.chars.input_coord
	current_coords := e.chars.current_coord
	visible := e.chars.is_visible
	visual_symbols := e.chars.visual
	visual_fg := e.chars.visual
	available := make([dynamic]int, n, context.temp_allocator)
	star_symbols := Blackhole_Star_Symbols
	explode_directions := [5]engine.Coord {
		engine.coord(3, 0),
		engine.coord(1, 2),
		engine.coord(-2, 1),
		engine.coord(-2, -1),
		engine.coord(1, -2),
	}
	for id, i in s.characters {
		s.final_colors[i] = engine.gradient_sample(sampler, spectrum[:], input_coords[id])
		s.star_colors[i] = engine.gradient_between_step(
			engine.Color{0x4A, 0x4A, 0x4D},
			engine.Color{0xFF, 0xFF, 0xFF},
			6,
			rand.int_max(7),
		)
		s.star_symbols[i] = star_symbols[rand.int_max(len(star_symbols))]
		s.star_coords[i] = engine.canvas_random_coord(e.canvas, false, false)
		current_coords[id] = s.star_coords[i]
		visual_symbols[id].symbol = s.star_symbols[i]
		visual_fg[id].fg = s.star_colors[i]
		visible[id] = true
		available[i] = i
		s.consume_steps[i] = max(
			engine.round_half_even(
				engine.line_length(s.star_coords[i], e.canvas.center, true) / 0.23,
			),
			1,
		)
	}
	for slot in 0 ..< ring_count {
		pick := rand.int_max(len(available))
		source := available[pick]
		unordered_remove(&available, pick)
		append(&s.ring_sources, source)
		s.ring_slot_by_source[source] = slot
		append(&s.ring_starts, -1)
		append(
			&s.ring_steps,
			max(
				engine.round_half_even(
					engine.line_length(s.star_coords[source], s.ring_positions[slot], true) / 0.7,
				),
				1,
			),
		)
		append(&s.ring_colors, s.config.star_colors[rand.int_max(len(s.config.star_colors))])
	}
	for id, i in s.characters {
		direction := explode_directions[rand.int_max(len(explode_directions))]
		target := engine.coord(
			input_coords[id].column + direction.column,
			input_coords[id].row + direction.row,
		)
		s.explode_targets[i] = target
		s.explode_steps[i] = max(
			engine.round_half_even(
				engine.line_length(e.canvas.center, target, true) / rand.float64_range(0.3, 0.4),
			),
			1,
		)
		s.return_steps[i] = max(
			engine.round_half_even(
				engine.line_length(target, input_coords[id], true) /
				rand.float64_range(0.04, 0.06),
			),
			1,
		)
		s.explode_colors[i] = s.config.star_colors[rand.int_max(len(s.config.star_colors))]
		s.explode_limit = max(s.explode_limit, s.explode_steps[i] + s.return_steps[i] + 30)
	}
	s.formation_delay = max(math.floor_div(100, max(ring_count, 1)), 6)
	s.delay = s.formation_delay
	s.phase = .Forming
}

blackhole_next :: proc(s: ^Blackhole_State, e: ^engine.Engine) -> bool {
	current_coords := e.chars.current_coord
	input_coords := e.chars.input_coord
	input_symbols := e.chars.input_symbol
	visual_symbols := e.chars.visual
	visual_fg := e.chars.visual
	visible := e.chars.is_visible

	for {
		switch s.phase {
		case .Forming:
			if s.next_ring < len(s.ring_sources) {
				if s.delay == 0 {
					s.ring_starts[s.next_ring] = s.phase_tick
					s.next_ring += 1
					s.delay = s.formation_delay
				} else {
					s.delay -= 1
				}
			}
			formed := s.next_ring == len(s.ring_sources)
			for source, slot in s.ring_sources {
				id := s.characters[source]
				start := s.ring_starts[slot]
				if start < 0 {
					formed = false
					continue
				}
				age := s.phase_tick - start
				steps := s.ring_steps[slot]
				current_coords[id] = engine.coord_on_line(
					s.star_coords[source],
					s.ring_positions[slot],
					ease.ease(.Sine_In_Out, f64(min(age + 1, steps)) / f64(steps)),
				)
				visual_symbols[id].symbol = "*"
				visual_fg[id].fg = s.config.blackhole_color
				e.chars.layer[id] = 1
				if age < steps do formed = false
			}
			if formed {
				s.phase = .Consuming
				s.phase_tick = 0
				continue
			}
			s.phase_tick += 1
			engine.frame(e, s.characters[:])
			return true

		case .Consuming:
			complete := true
			for id, i in s.characters {
				slot := s.ring_slot_by_source[i]
				if slot >= 0 {
					current_coords[id] = blackhole_ring_position(s, slot)
					visual_symbols[id].symbol = "*"
					visual_fg[id].fg = s.config.blackhole_color
					continue
				}
				steps := s.consume_steps[i]
				progress := f64(min(s.phase_tick + 1, steps)) / f64(steps)
				current_coords[id] = engine.coord_on_line(
					s.star_coords[i],
					e.canvas.center,
					ease.ease(.Exponential_In, progress),
				)
				visual_fg[id].fg = engine.gradient_between_step(
					s.star_colors[i],
					engine.Color{0x00, 0x00, 0x00},
					10,
					min(s.phase_tick / 4, 10),
				)
				if s.phase_tick < steps do complete = false
			}
			s.rotation += 1
			if s.rotation == len(s.ring_positions) do s.rotation = 0
			if complete && s.phase_tick > 20 {
				s.phase = .Collapsing
				s.phase_tick = 0
				continue
			}
			s.phase_tick += 1
			engine.frame(e, s.characters[:])
			return true

		case .Collapsing:
			if s.phase_tick == 60 {
				for id, _ in s.characters {
					current_coords[id] = e.canvas.center
					visible[id] = true
					e.chars.layer[id] = 0
				}
				s.phase = .Exploding
				s.phase_tick = 0
				continue
			}
			for id, i in s.characters {
				slot := s.ring_slot_by_source[i]
				if slot < 0 {
					visible[id] = false
					continue
				}
				if s.phase_tick < 18 {
					current_coords[id] = engine.coord_on_line(
						blackhole_ring_position(s, slot),
						s.expanded_positions[slot],
						ease.ease(.Exponential_Out, f64(s.phase_tick + 1) / 18),
					)
				} else {
					current_coords[id] = engine.coord_on_line(
						s.expanded_positions[slot],
						e.canvas.center,
						ease.ease(.Exponential_In, f64(s.phase_tick - 17) / 42),
					)
				}
				visual_symbols[id].symbol = s.phase_tick < 45 ? "◉" : "●"
				visual_fg[id].fg = s.ring_colors[slot]
			}
			s.phase_tick += 1
			engine.frame(e, s.characters[:])
			return true

		case .Exploding:
			if s.phase_tick == s.explode_limit do return false
			for id, i in s.characters {
				age := s.phase_tick
				visual_symbols[id].symbol = input_symbols[id]
				if age < s.explode_steps[i] {
					current_coords[id] = engine.coord_on_line(
						e.canvas.center,
						s.explode_targets[i],
						ease.ease(.Exponential_Out, f64(age + 1) / f64(s.explode_steps[i])),
					)
					visual_fg[id].fg = s.explode_colors[i]
				} else {
					return_age := age - s.explode_steps[i]
					if return_age < s.return_steps[i] {
						current_coords[id] = engine.coord_on_line(
							s.explode_targets[i],
							input_coords[id],
							ease.ease(.Cubic_In, f64(return_age + 1) / f64(s.return_steps[i])),
						)
					}
					visual_fg[id].fg = engine.gradient_between_step(
						s.explode_colors[i],
						s.final_colors[i],
						10,
						min(return_age / 3, 10),
					)
				}
			}
			s.phase_tick += 1
			engine.frame(e, s.characters[:])
			return true
		}
	}
}
