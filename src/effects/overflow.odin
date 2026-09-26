package effects

import "../engine"

import "core:fmt"
import "core:math"
import "core:math/rand"

Overflow_Config :: struct {
	overflow_gradient_stops:  [dynamic]engine.Color,
	overflow_cycles_range:    Int_Range_Value,
	overflow_speed:           int,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

overflow_config_default :: proc() -> Overflow_Config {
	cfg := Overflow_Config {
		overflow_cycles_range    = {2, 4},
		overflow_speed           = 3,
		final_gradient_direction = .Vertical,
	}
	append(
		&cfg.overflow_gradient_stops,
		..[]engine.Color {
			engine.Color{0xf2, 0xeb, 0xc0},
			engine.Color{0x8d, 0xbf, 0xb3},
			engine.Color{0xf2, 0xeb, 0xc0},
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

overflow_parse :: proc(cfg: ^Overflow_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--overflow-gradient-stops":
			if !parse_colors_flag(&cfg.overflow_gradient_stops, args, &i, value, has_value) do return false
		case "--overflow-cycles-range":
			if !parse_int_range_flag(&cfg.overflow_cycles_range, args, &i, value, has_value) do return false
		case "--overflow-speed":
			if !parse_int_flag(&cfg.overflow_speed, args, &i, value, has_value) || cfg.overflow_speed <= 0 do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown overflow option: ", name)
			return false
		}
	}
	return true
}

Overflow_Row :: struct {
	span:  engine.Span,
	final: bool,
}

Overflow_State :: struct {
	config:            Overflow_Config,
	row_characters:    [dynamic]engine.Particle_Id,
	pending_rows:      [dynamic]Overflow_Row,
	pending_head:      int,
	active_rows:       [dynamic]Overflow_Row,
	overflow_gradient: [dynamic]engine.Color,
	delay:             int,
	color_handling:    engine.Existing_Color_Handling,
}

overflow_append_row :: proc(
	state: ^Overflow_State,
	characters: []engine.Particle_Id,
	final: bool,
) {
	span := engine.Span {
		start = len(state.row_characters),
		len   = len(characters),
	}
	append(&state.row_characters, ..characters)
	append(&state.pending_rows, Overflow_Row{span, final})
}

overflow_row_move_up :: proc(e: ^engine.Engine, characters: []engine.Particle_Id) {
	coords := e.particles.current_coord[:]
	for id in characters {
		engine.set_particle(e, id, coord = engine.Coord{coords[id].column, coords[id].row + (1)})
	}
}

overflow_row_setup :: proc(e: ^engine.Engine, characters: []engine.Particle_Id) {
	input := e.particles.initial_coord[:len(e.particles)]
	for id in characters {
		engine.set_particle(e, id, coord = engine.coord(input[id].column, 0))
	}
}

overflow_row_color :: proc(
	e: ^engine.Engine,
	characters: []engine.Particle_Id,
	color: engine.Color,
) {
	for id in characters {
		engine.set_visual(
			e,
			id,
			engine.Visual {
				symbol = engine.get_initial_visual(e, engine.Particle_Id(id)).symbol,
				fg = color,
			},
		)
	}
}

overflow_build :: proc(s: ^Overflow_State, e: ^engine.Engine) {
	s.color_handling = e.cfg.existing_color_handling
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
	query := engine.Particle_Query {
		e.particle_sets,
		e.particles.initial_coord[:len(e.particles)],
		e.canvas,
	}
	characters := engine.get_particles(
		query,
		engine.PARTICLE_FILTER_ALL_FILLS,
		.Top_Bottom_Left_Right,
	)
	defer delete(characters[:])
	final_colors := make([]engine.Color, len(e.particles), context.temp_allocator)
	black := engine.Color{0x00, 0x00, 0x00}
	for id in characters {
		coord := e.particles.initial_coord[id]
		if coord.row >= e.canvas.text_bottom &&
		   coord.row <= e.canvas.text_top &&
		   coord.column >= e.canvas.text_left &&
		   coord.column <= e.canvas.text_right {
			final_colors[id] = engine.gradient_sample(final_sampler, final_spectrum[:], coord)
		} else {
			final_colors[id] = black
		}
	}

	input_rows := engine.get_particles_grouped(query, engine.PARTICLE_FILTER_INPUT, .Row_T2B)
	defer engine.groups_delete(&input_rows)
	row_order := make([]int, len(input_rows.spans), context.temp_allocator)
	for &row_index, i in row_order do row_index = i
	cycles := rand.int_range(
		s.config.overflow_cycles_range.lo,
		s.config.overflow_cycles_range.hi + 1,
	)
	for _ in 0 ..< cycles {
		rand.shuffle(row_order)
		for row_index in row_order {
			source := engine.group_members(input_rows, row_index)
			start := len(s.row_characters)
			for id in source {
				copy_id := engine.add_particle(
					e,
					engine.get_initial_visual(e, engine.Particle_Id(id)).symbol,
					e.particles.initial_coord[id],
				)
				e.particles.initial_visual_id[copy_id] = e.particles.initial_visual_id[id]
				e.particles.preserve_initial_colors[copy_id] =
					e.particles.preserve_initial_colors[id]
				append(&s.row_characters, copy_id)
			}
			append(&s.pending_rows, Overflow_Row{{start, len(source)}, false})
		}
	}

	query = {e.particle_sets, e.particles.initial_coord[:len(e.particles)], e.canvas}
	final_rows := engine.get_particles_grouped(query, engine.PARTICLE_FILTER_ALL_FILLS, .Row_T2B)
	defer engine.groups_delete(&final_rows)
	for row_index in 0 ..< len(final_rows.spans) {
		row := engine.group_members(final_rows, row_index)
		for id in row {
			if id < engine.Particle_Id(len(final_colors)) {
				if s.color_handling == .Dynamic {
					visual := engine.get_visual(e, id)
					engine.dynamic_apply_input_colors(
						&visual,
						engine.get_initial_visual(e, engine.Particle_Id(id)),
					)
					engine.set_visual(e, id, visual)
				} else {
					engine.set_visual(
						e,
						id,
						engine.Visual {
							symbol = engine.get_visual(e, id).symbol,
							fg = final_colors[id],
						},
					)
				}
			}
		}
		overflow_append_row(s, row, true)
	}

	reserve(&s.active_rows, len(s.pending_rows))
	steps := max(
		math.floor_div(e.canvas.top, max(1, len(s.config.overflow_gradient_stops) - 1)),
		1,
	)
	s.overflow_gradient = engine.gradient_make(
		s.config.overflow_gradient_stops[:],
		[]int{steps},
		false,
	)
}

overflow_next :: proc(s: ^Overflow_State, e: ^engine.Engine) -> ([]engine.Particle_Id, bool) {
	if s.pending_head >= len(s.pending_rows) do return nil, false
	if s.delay == 0 {
		for _ in 0 ..< rand.int_range(1, s.config.overflow_speed + 1) {
			if s.pending_head >= len(s.pending_rows) do break
			for row in s.active_rows {
				characters := engine.span_slice(s.row_characters[:], row.span)
				overflow_row_move_up(e, characters)
				if !row.final {
					head_row := e.particles.current_coord[characters[0]].row
					index := min(head_row, len(s.overflow_gradient) - 1)
					overflow_row_color(e, characters, s.overflow_gradient[index])
				}
			}
			next := s.pending_rows[s.pending_head]
			s.pending_head += 1
			characters := engine.span_slice(s.row_characters[:], next.span)
			overflow_row_setup(e, characters)
			overflow_row_move_up(e, characters)
			if !next.final {
				overflow_row_color(e, characters, s.overflow_gradient[0])
			}
			for id in characters {
				engine.set_particle(e, id, visible = true)
			}
			append(&s.active_rows, next)
		}
		s.delay = rand.int_range(0, 4)
	} else {
		s.delay -= 1
	}

	write := 0
	for row in s.active_rows {
		characters := engine.span_slice(s.row_characters[:], row.span)
		if e.particles.current_coord[characters[0]].row <= e.canvas.top {
			s.active_rows[write] = row
			write += 1
		}
	}
	resize(&s.active_rows, write)
	return nil, true
}
