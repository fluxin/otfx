package effects

import engine "../engine"

import "core:fmt"
import ease "core:math/ease"
import rand "core:math/rand"

Rings_Config :: struct {
	ring_colors:              [dynamic]engine.Color,
	ring_gap:                 f64,
	spin_duration:            int,
	spin_speed:               Float_Range_Value,
	disperse_duration:        int,
	spin_disperse_cycles:     int,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

rings_config_default :: proc() -> Rings_Config {
	cfg := Rings_Config {
		ring_gap                 = 0.1,
		spin_duration            = 200,
		spin_speed               = {0.25, 1.0},
		disperse_duration        = 200,
		spin_disperse_cycles     = 3,
		final_gradient_direction = .Vertical,
	}
	append(
		&cfg.ring_colors,
		engine.Color{0xab, 0x48, 0xff},
		engine.Color{0xe7, 0xb2, 0xb2},
		engine.Color{0xff, 0xfe, 0xbd},
	)
	append(&cfg.final_gradient_stops, ..cfg.ring_colors[:])
	append(&cfg.final_gradient_steps, 12)
	return cfg
}

rings_parse :: proc(cfg: ^Rings_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--ring-colors":
			if !parse_colors_flag(&cfg.ring_colors, args, &i, value, has_value) do return false
		case "--ring-gap":
			if !parse_float_flag(&cfg.ring_gap, args, &i, value, has_value) || cfg.ring_gap <= 0 do return false
		case "--spin-duration":
			if !parse_int_flag(&cfg.spin_duration, args, &i, value, has_value) do return false
		case "--spin-speed":
			if !parse_float_range_flag(&cfg.spin_speed, args, &i, value, has_value) do return false
		case "--disperse-duration":
			if !parse_int_flag(&cfg.disperse_duration, args, &i, value, has_value) do return false
		case "--spin-disperse-cycles":
			if !parse_int_flag(&cfg.spin_disperse_cycles, args, &i, value, has_value) do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown rings option: ", name)
			return false
		}
	}
	return true
}

Ring :: struct {
	ccw:            [dynamic]engine.Coord,
	cw:             [dynamic]engine.Coord,
	ring_gap:       int,
	color:          engine.Color,
	rotation_speed: f64,
}

Rings_Phase :: enum {
	Start,
	Disperse,
	Spin,
	Final,
	Complete,
}

Rings_Mode :: enum u8 {
	Idle,
	Approach_Disperse,
	Disperse_Loop,
	Condense,
	Rotate,
	External,
	Home,
	Complete,
}

// One row per source glyph. Ring geometry is shared, while this table owns
// only changing trajectory state. No row has a path, scene, event list, or
// heap-owned waypoint chain.
Rings_State :: struct {
	config:             Rings_Config,
	ids:                [dynamic]engine.Particle_Id,
	final_colors:       [dynamic]engine.Color,
	ring_by_slot:       [dynamic]int, // -1 for external glyphs
	clockwise:          [dynamic]u8,
	target_slots:       [dynamic]int,
	waypoint_indices:   [dynamic]int,
	waypoints:          [dynamic][5]engine.Coord,
	origins:            [dynamic]engine.Coord,
	targets:            [dynamic]engine.Coord,
	steps:              [dynamic]int,
	max_steps:          [dynamic]int,
	active_slots:       [dynamic]int,
	modes:              [dynamic]Rings_Mode,
	rings:              [dynamic]Ring,
	phase:              Rings_Phase,
	initial_disperse:   bool,
	spin_remaining:     int,
	disperse_remaining: int,
	cycles_remaining:   int,
	start_remaining:    int,
	color_tick:         int,
	color_sample:       int,
	color_handling:     engine.Existing_Color_Handling,
}

rings_coords :: proc(s: ^Rings_State, slot: int) -> []engine.Coord {
	ring := &s.rings[s.ring_by_slot[slot]]
	return s.clockwise[slot] != 0 ? ring.cw[:] : ring.ccw[:]
}

rings_begin_line :: proc(
	s: ^Rings_State,
	slot: int,
	origin: engine.Coord,
	target: engine.Coord,
	speed: f64,
) {
	s.origins[slot], s.targets[slot] = origin, target
	s.steps[slot] = 0
	s.max_steps[slot] = max(
		engine.round_to_int(engine.line_length(origin, target, true) / speed),
		1,
	)
}

rings_build :: proc(s: ^Rings_State, e: ^engine.Engine) {
	s.color_handling = e.cfg.existing_color_handling
	final_spectrum := engine.gradient_make(
		s.config.final_gradient_stops[:],
		s.config.final_gradient_steps[:],
		false,
	)
	defer delete(final_spectrum[:])
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
	chars := engine.get_particles(query, engine.PARTICLE_FILTER_INPUT, .Top_Bottom_Left_Right)
	defer delete(chars[:])
	n := len(chars)
	append(&s.ids, ..chars[:])
	s.final_colors = make([dynamic]engine.Color, n)
	s.ring_by_slot = make([dynamic]int, n)
	s.clockwise = make([dynamic]u8, n)
	s.target_slots = make([dynamic]int, n)
	s.waypoint_indices = make([dynamic]int, n)
	s.waypoints = make([dynamic][5]engine.Coord, n)
	s.origins = make([dynamic]engine.Coord, n)
	s.targets = make([dynamic]engine.Coord, n)
	s.steps = make([dynamic]int, n)
	s.max_steps = make([dynamic]int, n)
	s.modes = make([dynamic]Rings_Mode, n)

	initial_coords := e.particles.initial_coord

	visible_flags := e.particles.flags
	for id, slot in chars {
		s.final_colors[slot] = engine.gradient_sample(
			sampler,
			final_spectrum[:],
			initial_coords[id],
		)
		s.ring_by_slot[slot] = -1
		if s.color_handling == .Dynamic {
			appearance := engine.get_appearance(e, id)
			engine.dynamic_apply_input_colors(
				&appearance,
				engine.get_initial_appearance(e, engine.Particle_Id(id)),
			)
			engine.set_appearance(e, id, appearance)
		} else {
			engine.set_foreground(e, id, s.final_colors[slot])
		}
		visible_flags[id] += {.Visible}
	}

	ring_gap := max(
		engine.round_to_int(f64(min(e.canvas.top, e.canvas.right)) * s.config.ring_gap),
		1,
	)
	center := e.canvas.center
	for radius := 1; radius < max(e.canvas.right, e.canvas.top); radius += ring_gap {
		coords := engine.find_coords_on_circle(center, radius, 7 * radius, true)
		in_canvas := 0
		for p in coords {
			if engine.canvas_in(e.canvas, p) do in_canvas += 1
		}
		if f64(in_canvas) / f64(max(len(coords), 1)) < 0.25 {
			delete(coords[:])
			break
		}
		ring := Ring {
			ccw            = coords,
			ring_gap       = ring_gap,
			color          = s.config.ring_colors[len(s.rings) % len(s.config.ring_colors)],
			rotation_speed = rand.float64_range(s.config.spin_speed.lo, s.config.spin_speed.hi),
		}
		ring.cw = make([dynamic]engine.Coord, len(coords))
		for i in 0 ..< len(coords) do ring.cw[len(coords) - 1 - i] = coords[i]
		append(&s.rings, ring)
	}

	pending := make([dynamic]int, n)
	for i in 0 ..< n do pending[i] = i
	rand.shuffle(pending[:])
	next := 0
	for ri in 0 ..< len(s.rings) {
		ring := &s.rings[ri]
		for point_index in 0 ..< len(ring.ccw) {
			if next == n do break
			slot := pending[next]
			next += 1
			s.ring_by_slot[slot] = ri
			s.clockwise[slot] = u8(ri & 1)
			s.target_slots[slot] = point_index
		}
		if next == n do break
	}
	delete(pending[:])

	s.spin_remaining = s.config.spin_duration
	s.disperse_remaining = s.config.disperse_duration
	s.cycles_remaining = s.config.spin_disperse_cycles
	reserve(&s.active_slots, len(s.ids))
	s.start_remaining = 100
}

rings_begin_disperse :: proc(s: ^Rings_State, e: ^engine.Engine, initial: bool) {
	for slot in 0 ..< len(s.ids) {
		id := s.ids[slot]
		ring_index := s.ring_by_slot[slot]
		if ring_index < 0 {
			if initial {
				s.modes[slot] = .External
				rings_begin_line(
					s,
					slot,
					e.particles.current_coord[s.ids[slot]],
					engine.canvas_random_coord(e.canvas, true, false),
					0.8,
				)
			}
			continue
		}
		ring := &s.rings[ring_index]
		center :=
			initial ? rings_coords(s, slot)[s.target_slots[slot]] : e.particles.current_coord[id]
		// Sample the rectangle's column-major index without materializing it.
		// Keep the same five draws and coordinate ordering as the old pool.
		side := 2 * ring.ring_gap + 1
		for waypoint in 0 ..< 5 {
			index := rand.int_max(side * side)
			s.waypoints[slot][waypoint] = engine.coord(
				center.column - ring.ring_gap + index / side,
				center.row - ring.ring_gap + index % side,
			)
		}
		s.waypoint_indices[slot] = 0
		if initial {
			s.modes[slot] = .Approach_Disperse
			rings_begin_line(
				s,
				slot,
				e.particles.current_coord[s.ids[slot]],
				s.waypoints[slot][0],
				0.3,
			)
		} else {
			s.modes[slot] = .Disperse_Loop
			rings_begin_line(
				s,
				slot,
				e.particles.current_coord[s.ids[slot]],
				s.waypoints[slot][0],
				0.14,
			)
		}
	}
	s.color_tick = 0
}

rings_begin_spin :: proc(s: ^Rings_State, e: ^engine.Engine) {
	for slot in 0 ..< len(s.ids) {
		if s.ring_by_slot[slot] < 0 do continue
		s.modes[slot] = .Condense
		target := rings_coords(s, slot)[s.target_slots[slot]]
		rings_begin_line(s, slot, e.particles.current_coord[s.ids[slot]], target, 0.1)
	}
	s.color_tick = 0
}

rings_begin_final :: proc(s: ^Rings_State, e: ^engine.Engine) {
	for slot in 0 ..< len(s.ids) {
		id := s.ids[slot]
		engine.set_particle(e, id, engine.Visible(true))
		s.modes[slot] = .Home
		rings_begin_line(
			s,
			slot,
			e.particles.current_coord[s.ids[slot]],
			e.particles.initial_coord[id],
			0.8,
		)
	}
}

rings_update_colors :: proc(s: ^Rings_State, e: ^engine.Engine) {
	if s.color_handling == .Dynamic do return // applied once during build
	sample := 0
	switch s.phase {
	case .Disperse:
		sample = 1 + min(s.color_tick / 10, 8)
	case .Spin:
		sample = 10 + min(s.color_tick / 3, 8)
	case .Final:
		sample = 19
	case .Start, .Complete:
		return
	}
	if s.color_sample == sample do return
	s.color_sample = sample
	for slot in 0 ..< len(s.ids) {
		id := s.ids[slot]
		appearance := engine.get_appearance(e, id)

		ring_index := s.ring_by_slot[slot]
		if ring_index < 0 {
			if s.phase == .Final {
				appearance.colors.fg = s.final_colors[slot]
			}
			engine.set_appearance(e, id, appearance)
			continue
		}
		ring_color := s.rings[ring_index].color
		switch s.phase {
		case .Disperse:
			appearance.colors.fg = engine.gradient_between_step(
				ring_color,
				s.final_colors[slot],
				8,
				min(s.color_tick / 10, 8),
			)
		case .Spin:
			appearance.colors.fg = engine.gradient_between_step(
				s.final_colors[slot],
				ring_color,
				8,
				min(s.color_tick / 3, 8),
			)
		case .Final:
			appearance.colors.fg = s.final_colors[slot]
		case .Start, .Complete:
		}
		engine.set_appearance(e, id, appearance)
	}
}

rings_update_motion :: proc(s: ^Rings_State, e: ^engine.Engine) {
	write := 0
	for slot in s.active_slots {
		mode := s.modes[slot]
		id := s.ids[slot]
		step := s.steps[slot] + 1
		maximum := s.max_steps[slot]
		factor := f64(step) / f64(maximum)
		switch mode {
		case .Approach_Disperse:
			factor = ease.ease(.Cubic_Out, factor)
		case .External:
			factor = ease.ease(.Sine_Out, factor)
		case .Home:
			factor = ease.ease(.Quadratic_Out, factor)
		case .Disperse_Loop, .Condense, .Rotate, .Idle, .Complete:
		}
		position := engine.coord_on_line(s.origins[slot], s.targets[slot], factor)
		engine.set_particle(e, id, position)
		if step < maximum {
			s.active_slots[write] = slot
			write += 1
			s.steps[slot] = step
			continue
		}

		switch mode {
		case .Approach_Disperse:
			s.modes[slot] = .Disperse_Loop
			s.waypoint_indices[slot] = 0
			rings_begin_line(s, slot, position, s.waypoints[slot][0], 0.14)
		case .Disperse_Loop:
			next := s.waypoint_indices[slot] + 1
			if next == 5 do next = 0
			s.waypoint_indices[slot] = next
			rings_begin_line(s, slot, position, s.waypoints[slot][next], 0.14)
		case .Condense:
			s.modes[slot] = .Rotate
			rings_begin_line(
				s,
				slot,
				position,
				rings_coords(s, slot)[s.target_slots[slot]],
				s.rings[s.ring_by_slot[slot]].rotation_speed,
			)
		case .Rotate:
			coords_for_ring := rings_coords(s, slot)
			next := s.target_slots[slot] + 1
			if next == len(coords_for_ring) do next = 0
			s.target_slots[slot] = next
			rings_begin_line(
				s,
				slot,
				position,
				coords_for_ring[next],
				s.rings[s.ring_by_slot[slot]].rotation_speed,
			)
		case .External:
			engine.set_particle(e, id, engine.Visible(false))
			s.modes[slot] = .Complete
		case .Home:
			s.modes[slot] = .Complete
		case .Idle, .Complete:
		}
		if s.modes[slot] != .Complete {
			s.active_slots[write] = slot
			write += 1
		}
	}
	resize(&s.active_slots, write)
}

rings_next :: proc(s: ^Rings_State, e: ^engine.Engine) -> bool {
	if s.phase == .Complete do return false
	previous_phase, previously_dispersed := s.phase, s.initial_disperse
	switch s.phase {
	case .Start:
		if s.start_remaining == 0 {
			s.phase = .Disperse
		} else {
			s.start_remaining -= 1
		}
	case .Disperse:
		if !s.initial_disperse {
			s.initial_disperse = true
			rings_begin_disperse(s, e, true)
		} else if s.disperse_remaining == 0 {
			s.phase = .Spin
			s.cycles_remaining -= 1
			s.spin_remaining = s.config.spin_duration
			rings_begin_spin(s, e)
		} else {
			s.disperse_remaining -= 1
		}
	case .Spin:
		if s.spin_remaining == 0 {
			if s.cycles_remaining == 0 {
				s.phase = .Final
				rings_begin_final(s, e)
			} else {
				s.phase = .Disperse
				s.disperse_remaining = s.config.disperse_duration
				rings_begin_disperse(s, e, false)
			}
		} else {
			s.spin_remaining -= 1
		}
	case .Final:
		if len(s.active_slots) == 0 do s.phase = .Complete
	case .Complete:
	}
	if previous_phase != s.phase || previously_dispersed != s.initial_disperse {
		clear(&s.active_slots)
		for mode, slot in s.modes {
			if mode != .Idle && mode != .Complete do append(&s.active_slots, slot)
		}
	}
	rings_update_colors(s, e)
	rings_update_motion(s, e)
	s.color_tick += 1
	return true
}
