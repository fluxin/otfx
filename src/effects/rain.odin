package effects

import "../engine"
import "core:math/ease"
import "core:math/rand"

import "core:fmt"
import "core:slice"

// rain — raindrops fall from the top of the canvas; on landing they fade
// into the final gradient.

Rain_Config :: struct {
	rain_colors:              [dynamic]engine.Color,
	movement_speed:           Float_Range_Value,
	rain_symbols:             [dynamic]string,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
	movement_easing:          ease.Ease,
}

rain_config_default :: proc() -> Rain_Config {
	cfg := Rain_Config {
		movement_speed           = {0.33, 0.57},
		final_gradient_direction = .Diagonal,
		movement_easing          = .Quartic_In,
	}
	append(
		&cfg.rain_colors,
		..[]engine.Color {
			engine.Color{0x00, 0x31, 0x5C},
			engine.Color{0x00, 0x4C, 0x8F},
			engine.Color{0x00, 0x75, 0xDB},
			engine.Color{0x3F, 0x91, 0xD9},
			engine.Color{0x78, 0xB9, 0xF2},
			engine.Color{0x9A, 0xC8, 0xF5},
			engine.Color{0xB8, 0xD8, 0xF8},
			engine.Color{0xE3, 0xEF, 0xFC},
		},
	)
	append(&cfg.rain_symbols, ..[]string{"o", ".", ",", "*", "|"})
	append(
		&cfg.final_gradient_stops,
		..[]engine.Color {
			engine.Color{0x48, 0x8b, 0xff},
			engine.Color{0xb2, 0xe7, 0xde},
			engine.Color{0x57, 0xea, 0xf7},
		},
	)
	append(&cfg.final_gradient_steps, 12)
	return cfg
}

rain_parse :: proc(cfg: ^Rain_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--rain-colors":
			if !parse_colors_flag(&cfg.rain_colors, args, &i, value, has_value) do return false
		case "--movement-speed":
			if !parse_float_range_flag(&cfg.movement_speed, args, &i, value, has_value) do return false
		case "--rain-symbols":
			if !parse_symbols_flag(&cfg.rain_symbols, args, &i, value, has_value) do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case "--movement-easing":
			if !parse_ease_flag(&cfg.movement_easing, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown rain option: ", name)
			return false
		}
	}
	return true
}

Rain_State :: struct {
	config:         Rain_Config,
	characters:     [dynamic]engine.Particle_Id,
	index_by_id:    [dynamic]int,
	pending:        [dynamic]engine.Particle_Id,
	by_row:         [dynamic]engine.Particle_Id, // flat pool sorted by input row asc
	active_slots:   [dynamic]int, // dense slots that still move or fade
	final_colors:   [dynamic]engine.Color,
	drop_colors:    [dynamic]engine.Color,
	drop_symbols:   [dynamic]string,
	max_steps:      [dynamic]int,
	start_ticks:    [dynamic]int,
	by_row_head:    int,
	tick:           int,
	color_handling: engine.Existing_Color_Handling,
}

rain_build :: proc(s: ^Rain_State, e: ^engine.Engine) {
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
	initial_coords := e.particles.initial_coord[:len(e.particles)]
	Rain_Row :: struct {
		id:          engine.Particle_Id,
		row, column: int,
	}
	n := len(s.characters)
	s.color_handling = e.cfg.existing_color_handling
	s.index_by_id = make([dynamic]int, len(e.particles))
	s.final_colors = make([dynamic]engine.Color, n)
	s.drop_colors = make([dynamic]engine.Color, n)
	s.drop_symbols = make([dynamic]string, n)
	s.max_steps = make([dynamic]int, n)
	s.start_ticks = make([dynamic]int, n)
	reserve(&s.pending, n)
	reserve(&s.active_slots, n)
	rows := make([]Rain_Row, n)
	defer delete(rows)

	for id, i in s.characters {
		s.index_by_id[id] = i
		c := initial_coords[id]
		rows[i] = {id, c.row, c.column}
		s.final_colors[i] = engine.gradient_sample(sampler, spectrum[:], c)
		s.drop_colors[i] = s.config.rain_colors[rand.int_max(len(s.config.rain_colors))]
		s.drop_symbols[i] = s.config.rain_symbols[rand.int_max(len(s.config.rain_symbols))]
		e.particles.current_coord[id] = engine.coord(c.column, e.canvas.top)
		speed := rand.float64_range(s.config.movement_speed.lo, s.config.movement_speed.hi)
		s.max_steps[i] = max(
			engine.round_half_even(
				engine.line_length(e.particles.current_coord[id], c, true) / speed,
			),
			1,
		)
		s.start_ticks[i] = -1
	}
	// One flat pool sorted by input row ascending; the front run of equal rows
	// is the min-row group.
	slice.sort_by(rows, proc(a, b: Rain_Row) -> bool {
			if a.row != b.row do return a.row < b.row
			return a.column < b.column
		})
	s.by_row = make([dynamic]engine.Particle_Id, len(rows))
	for row, i in rows do s.by_row[i] = row.id
}

rain_next :: proc(s: ^Rain_State, e: ^engine.Engine) -> bool {
	by_row := s.by_row[:]
	pending := &s.pending
	initial_coords := e.particles.initial_coord[:len(e.particles)]
	visible := e.particles.is_visible[:]
	if s.by_row_head >= len(by_row) && len(pending^) == 0 && len(s.active_slots) == 0 {
		return false
	}
	if len(pending^) == 0 && s.by_row_head < len(by_row) {
		// Consume the next row span by advancing a cursor; the sorted pool stays
		// fixed instead of shifting every remaining row toward the front.
		row0 := initial_coords[by_row[s.by_row_head]].row
		k := s.by_row_head
		for k < len(by_row) && initial_coords[by_row[k]].row == row0 {
			k += 1
		}
		append(pending, ..by_row[s.by_row_head:k])
		s.by_row_head = k
	}
	if len(pending^) > 0 {
		for _ in 0 ..< rand.int_range(1, 3) {
			if len(pending^) == 0 do break
			idx := rand.int_max(len(pending^))
			next := pending[idx]
			unordered_remove(pending, idx)
			slot := s.index_by_id[next]
			s.start_ticks[slot] = s.tick
			engine.set_particle(e, next, visible = true)
			append(&s.active_slots, slot)
		}
	}
	write := 0
	for slot in s.active_slots {
		id := s.characters[slot]
		start := s.start_ticks[slot]
		age := s.tick - start
		if age < s.max_steps[slot] - 1 {
			progress := f64(age + 1) / f64(s.max_steps[slot])
			engine.set_particle(
				e,
				id,
				coord = engine.coord_on_line(
					engine.coord(e.particles.initial_coord[id].column, e.canvas.top),
					e.particles.initial_coord[id],
					ease.ease(s.config.movement_easing, progress),
				),
			)
			engine.set_symbol(e, id, s.drop_symbols[slot])
			engine.set_foreground(e, id, s.drop_colors[slot])
		} else {
			engine.set_particle(e, id, coord = e.particles.initial_coord[id])
			engine.set_symbol(e, id, engine.get_initial_visual(e, engine.Particle_Id(id)).symbol)
			fade_tick := age - (s.max_steps[slot] - 1)
			fade_step := min(fade_tick / 3, 7)
			if s.color_handling == .Dynamic {
				visual := engine.get_visual(e, id)
				engine.dynamic_gradient_to_input(
					&visual,
					s.drop_colors[slot],
					engine.get_initial_visual(e, engine.Particle_Id(id)),
					7,
					fade_step,
				)
				engine.set_visual(e, id, visual)
			} else {
				engine.set_foreground(
					e,
					id,
					engine.gradient_between_step(
						s.drop_colors[slot],
						s.final_colors[slot],
						7,
						fade_step,
					),
				)
			}
		}
		// The final full-color fade is at age max_steps + 22.
		if age + 1 < s.max_steps[slot] + 23 {
			s.active_slots[write] = slot
			write += 1
		}
	}
	resize(&s.active_slots, write)
	s.tick += 1
	return true
}
