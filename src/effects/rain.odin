package effects

import "../engine"
import "core:math/ease"

import "core:fmt"
import "core:slice"

// rain — raindrops fall from the top of the canvas; on landing they fade
// into the final gradient.

Rain_Config :: struct {
	rain_colors:              [dynamic]engine.Color,
	movement_speed:           Float_Range_Value,
	rain_symbols:             [dynamic]rune,
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
	append(&cfg.rain_symbols, ..[]rune{'o', '.', ',', '*', '|'})
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
	targets:        [dynamic]engine.Coord,
	drop_codes:     [dynamic]engine.Appearance_Id,
	fades:          engine.Appearance_Ramp,
	fade_index:     [dynamic]int,
	drop_symbols:   [dynamic]rune,
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
	s.targets = make([dynamic]engine.Coord, n)
	s.drop_codes = make([dynamic]engine.Appearance_Id, n)
	s.drop_symbols = make([dynamic]rune, n)
	s.max_steps = make([dynamic]int, n)
	s.start_ticks = make([dynamic]int, n)
	reserve(&s.pending, n)
	reserve(&s.active_slots, n)
	if n == 0 do return

	rows := make([]Rain_Row, n, context.temp_allocator)
	defer delete(rows, context.temp_allocator)

	palette_codes := make([]engine.Appearance_Id, len(s.config.rain_colors), context.temp_allocator)
	defer delete(palette_codes, context.temp_allocator)
	for rc, ci in s.config.rain_colors {
		palette_codes[ci] = engine.prepare_appearance(e, {colors = {fg = rc}})
	}
	fade_tweens := make([]engine.Tween(engine.Appearance), n, context.temp_allocator)
	defer delete(fade_tweens, context.temp_allocator)

	for id, i in s.characters {
		s.index_by_id[id] = i
		c := initial_coords[id]
		s.targets[i] = c
		rows[i] = {id, c.row, c.column}
		ci := engine.random_below(len(s.config.rain_colors))
		drop_color := s.config.rain_colors[ci]
		s.drop_codes[i] = palette_codes[ci]
		s.drop_symbols[i] = s.config.rain_symbols[engine.random_below(len(s.config.rain_symbols))]
		if s.color_handling == .Dynamic {
			init_style := engine.get_initial_appearance(e, id)
			fade_tweens[i] = {
				from = {colors = {drop_color, drop_color}},
				to   = {colors = init_style.colors},
			}
		} else {
			final_color := engine.gradient_sample(sampler, spectrum[:], c)
			fade_tweens[i] = {
				from = {colors = {fg = drop_color}},
				to   = {colors = {fg = final_color}},
			}
		}
		origin := engine.coord(c.column, e.canvas.top)
		e.particles.current_coord[id] = origin
		speed := engine.random_float_range(s.config.movement_speed.lo, s.config.movement_speed.hi)
		s.max_steps[i] = max(
			engine.round_to_int(
				engine.line_length(origin, c, true) / speed,
			),
			1,
		)
		s.start_ticks[i] = -1
	}

	unique_tweens: [dynamic]engine.Tween(engine.Appearance)
	unique_tweens, s.fade_index = engine.group_values(fade_tweens)
	defer delete(unique_tweens)
	s.fades = engine.ramp_make(e, unique_tweens[:], 7)

	// One flat pool sorted by input row ascending; the front run of equal rows
	// is the min-row group.
	slice.sort_by(rows, proc(a, b: Rain_Row) -> bool {
			if a.row != b.row do return a.row < b.row
			return a.column < b.column
		})
	s.by_row = make([dynamic]engine.Particle_Id, len(rows))
	for row, i in rows do s.by_row[i] = row.id
}

rain_next :: proc(s: ^Rain_State, e: ^engine.Engine) -> bool #no_bounds_check {
	by_row := s.by_row[:]
	pending := &s.pending
	initial_coords := e.particles.initial_coord[:len(e.particles)]
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
		for _ in 0 ..< engine.random_range(1, 3) {
			if len(pending^) == 0 do break
			idx := engine.random_below(len(pending^))
			next := pending[idx]
			unordered_remove(pending, idx)
			slot := s.index_by_id[next]
			s.start_ticks[slot] = s.tick
			engine.set_visible(e, next, true)
			append(&s.active_slots, slot)
		}
	}
	top_row := e.canvas.top
	write := 0
	for slot in s.active_slots {
		id := s.characters[slot]
		start := s.start_ticks[slot]
		age := s.tick - start
		max_step := s.max_steps[slot]
		target := s.targets[slot]
		if age < max_step - 1 {
			progress := f64(age + 1) / f64(max_step)
			engine.set_position(
				e,
				id,
				engine.tween(
					engine.coord(target.column, top_row),
					target,
					ease.ease(s.config.movement_easing, progress),
				),
			)
			if age == 0 {
				engine.set_symbol(e, id, s.drop_symbols[slot])
				engine.set_appearance(e, id, s.drop_codes[slot])
			}
		} else {
			if age == max_step - 1 {
				engine.set_position(e, id, target)
				engine.set_symbol(e, id, e.particles.initial_symbol[id])
			}
			fade_tick := age - (max_step - 1)
			if fade_tick <= 21 && fade_tick % 3 == 0 {
				fade_step := min(fade_tick / 3, 7)
				engine.set_appearance(e, id, engine.ramp_code(s.fades, s.fade_index[slot], fade_step))
			}
		}
		// The final full-color fade is at age max_steps + 22.
		if age + 1 < max_step + 23 {
			s.active_slots[write] = slot
			write += 1
		}
	}
	resize(&s.active_slots, write)
	s.tick += 1
	return true
}
