package effects

import "../engine"
import "core:slice"

import "core:fmt"

// beams — light beams sweep rows and columns illuminating the canvas, then a
// final wipe brightens everything into place.

Beams_Config :: struct {
	beam_row_symbols:         [dynamic]rune,
	beam_column_symbols:      [dynamic]rune,
	beam_delay:               int,
	beam_row_speed_range:     Int_Range_Value,
	beam_column_speed_range:  Int_Range_Value,
	beam_gradient_stops:      [dynamic]engine.Color,
	beam_gradient_steps:      [dynamic]int,
	beam_gradient_frames:     int,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_frames:    int,
	final_gradient_direction: engine.Gradient_Direction,
	final_wipe_speed:         int,
}

beams_config_default :: proc() -> Beams_Config {
	cfg := Beams_Config {
		beam_delay               = 6,
		beam_row_speed_range     = {15, 60},
		beam_column_speed_range  = {9, 15},
		beam_gradient_frames     = 2,
		final_gradient_frames    = 4,
		final_gradient_direction = .Vertical,
		final_wipe_speed         = 3,
	}
	append(&cfg.beam_row_symbols, ..[]rune{'▂', '▁', '_'})
	append(&cfg.beam_column_symbols, ..[]rune{'▌', '▍', '▎', '▏'})
	append(
		&cfg.beam_gradient_stops,
		..[]engine.Color {
			engine.Color{0xff, 0xff, 0xff},
			engine.Color{0x00, 0xD1, 0xFF},
			engine.Color{0x8A, 0x00, 0x8A},
		},
	)
	append(&cfg.beam_gradient_steps, ..[]int{2, 6})
	append(
		&cfg.final_gradient_stops,
		..[]engine.Color {
			engine.Color{0x8A, 0x00, 0x8A},
			engine.Color{0x00, 0xD1, 0xFF},
			engine.Color{0xff, 0xff, 0xff},
		},
	)
	append(&cfg.final_gradient_steps, 12)
	return cfg
}

beams_parse :: proc(cfg: ^Beams_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--beam-row-symbols":
			if !parse_symbols_flag(&cfg.beam_row_symbols, args, &i, value, has_value) do return false
		case "--beam-column-symbols":
			if !parse_symbols_flag(&cfg.beam_column_symbols, args, &i, value, has_value) do return false
		case "--beam-delay":
			if !parse_int_flag(&cfg.beam_delay, args, &i, value, has_value) do return false
		case "--beam-row-speed-range":
			if !parse_int_range_flag(&cfg.beam_row_speed_range, args, &i, value, has_value) do return false
		case "--beam-column-speed-range":
			if !parse_int_range_flag(&cfg.beam_column_speed_range, args, &i, value, has_value) do return false
		case "--beam-gradient-stops":
			if !parse_colors_flag(&cfg.beam_gradient_stops, args, &i, value, has_value) do return false
		case "--beam-gradient-steps":
			if !parse_ints_flag(&cfg.beam_gradient_steps, args, &i, value, has_value) do return false
		case "--beam-gradient-frames":
			if !parse_int_flag(&cfg.beam_gradient_frames, args, &i, value, has_value) do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-frames":
			if !parse_int_flag(&cfg.final_gradient_frames, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case "--final-wipe-speed":
			if !parse_int_flag(&cfg.final_wipe_speed, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown beams option: ", name)
			return false
		}
	}
	return true
}

Beam_Direction :: enum {
	Row,
	Column,
}

// A beam group is a span into the flat character pool plus its own cursor.
Beam_Group :: struct {
	span:      engine.Span,
	head:      int,
	direction: Beam_Direction,
	speed:     f64,
	counter:   f64,
}

Beams_Phase :: enum {
	Beams,
	Final_Wipe,
	Complete,
}

Beams_State :: struct {
	config:             Beams_Config,
	characters:         [dynamic]engine.Particle_Id,
	style_by_id:        [dynamic]int,
	fade_ramp:          engine.Appearance_Ramp,
	brighten_ramp:      engine.Appearance_Ramp,
	beam_start_ticks:   [dynamic]int,
	beam_modes:         [dynamic]Beam_Direction,
	wipe_start_ticks:   [dynamic]int,
	beam_palette:       [dynamic]engine.Color,
	row_symbols:        [dynamic]rune,
	row_codes:          [dynamic]engine.Appearance_Id,
	column_symbols:     [dynamic]rune,
	column_codes:       [dynamic]engine.Appearance_Id,
	group_chars:        [dynamic]engine.Particle_Id,
	groups:             [dynamic]Beam_Group,
	pending:            [dynamic]int, // group handles
	pending_head:       int,
	active:             [dynamic]int,
	appearance_active:  [dynamic]engine.Particle_Id,
	beam_end, wipe_end: int,
	final_wipe_groups:  engine.Particle_Groups,
	final_wipe_idx:     int,
	delay:              int,
	tick:               int,
	phase:              Beams_Phase,
	color_handling:     engine.Existing_Color_Handling,
}

beams_prepare_lane :: proc(
	e: ^engine.Engine,
	colors: []engine.Color,
	symbols: []rune,
) -> (
	expanded_symbols: [dynamic]rune,
	codes: [dynamic]engine.Appearance_Id,
) {
	entries := max(len(colors), len(symbols))
	expanded_colors := engine.sequence_expand(colors, entries)
	defer delete(expanded_colors)
	expanded_symbols = engine.sequence_expand(symbols, entries)
	codes = make([dynamic]engine.Appearance_Id, entries)
	for color, i in expanded_colors {
		if i > 0 && color == expanded_colors[i - 1] {
			codes[i] = codes[i - 1]
		} else {
			codes[i] = engine.prepare_appearance(e, engine.Appearance{colors = {fg = color}})
		}
	}
	return
}

beams_make_group :: proc(
	group_chars: ^[dynamic]engine.Particle_Id,
	g: []engine.Particle_Id,
	direction: Beam_Direction,
	rng: Int_Range_Value,
) -> Beam_Group {
	speed := f64(engine.random_range(rng.lo, rng.hi + 1)) * 0.1
	// get_particles_grouped already orders row groups by column and column
	// groups by row. Consume that producer contract instead of sorting again.
	if engine.random_below(2) == 0 do slice.reverse(g)
	span := engine.Span {
		start = len(group_chars),
		len   = len(g),
	}
	append(group_chars, ..g)
	return {span = span, direction = direction, speed = speed}
}

beams_build :: proc(s: ^Beams_State, e: ^engine.Engine) {
	s.final_wipe_groups = engine.get_particles_grouped(
		engine.Particle_Query {
			e.particle_sets,
			e.particles.initial_coord[:len(e.particles)],
			e.canvas,
		},
		engine.PARTICLE_FILTER_INPUT,
		.Diagonal_TL2BR,
	)

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
	beam_spectrum := engine.gradient_make(
		s.config.beam_gradient_stops[:],
		s.config.beam_gradient_steps[:],
		false,
	)
	defer delete(beam_spectrum[:])

	s.characters = engine.get_particles(
		engine.Particle_Query {
			e.particle_sets,
			e.particles.initial_coord[:len(e.particles)],
			e.canvas,
		},
		engine.PARTICLE_FILTER_ALL_FILLS,
		.Top_Bottom_Left_Right,
	)
	s.color_handling = e.cfg.existing_color_handling
	max_slot := 0
	for id in s.characters do max_slot = max(max_slot, int(id))
	s.style_by_id = make([dynamic]int, max_slot + 1)
	s.beam_start_ticks = make([dynamic]int, max_slot + 1)
	s.beam_modes = make([dynamic]Beam_Direction, max_slot + 1)
	s.wipe_start_ticks = make([dynamic]int, max_slot + 1)
	reserve(&s.appearance_active, len(s.characters))
	for i in 0 ..= max_slot do s.beam_start_ticks[i], s.wipe_start_ticks[i] = -1, -1

	final_styles := make([]engine.Appearance, len(s.characters), context.temp_allocator)
	defer delete(final_styles, context.temp_allocator)
	black := engine.Color{0x00, 0x00, 0x00}
	for id, i in s.characters {
		if .Fill in e.particles.flags[id] {
			final_styles[i] = {colors = {fg = black}}
		} else if s.color_handling == .Dynamic {
			final_styles[i] = {colors = engine.get_initial_appearance(e, id).colors}
		} else {
			c := e.particles.initial_coord[id]
			final_styles[i] = {colors = {fg = engine.gradient_sample(final_sampler, final_spectrum[:], c)}}
		}
	}
	unique_styles, slot_styles := engine.group_values(final_styles)
	defer delete(unique_styles)
	defer delete(slot_styles)
	for id, i in s.characters {
		s.style_by_id[id] = slot_styles[i]
	}
	fade_tweens := make([]engine.Tween(engine.Appearance), len(unique_styles), context.temp_allocator)
	brighten_tweens := make([]engine.Tween(engine.Appearance), len(unique_styles), context.temp_allocator)
	defer delete(fade_tweens, context.temp_allocator)
	defer delete(brighten_tweens, context.temp_allocator)
	for row_style, row in unique_styles {
		faded := row_style.colors
		if fg, ok := faded.fg.?; ok do faded.fg = engine.adjust_color_brightness(fg, 0.3)
		if bg, ok := faded.bg.?; ok do faded.bg = engine.adjust_color_brightness(bg, 0.3)
		fade_tweens[row] = {from = row_style, to = {colors = faded}}
		brighten_tweens[row] = {from = {colors = faded}, to = row_style}
	}
	s.fade_ramp = engine.ramp_make(e, fade_tweens, 10)
	s.brighten_ramp = engine.ramp_make(e, brighten_tweens, 10)

	// scenes on the row pass only (rows and columns share characters)
	row_groups := engine.get_particles_grouped(
		engine.Particle_Query {
			e.particle_sets,
			e.particles.initial_coord[:len(e.particles)],
			e.canvas,
		},
		engine.PARTICLE_FILTER_ALL_FILLS,
		.Row_B2T,
	)
	for gi in 0 ..< len(row_groups.spans) {
		g := engine.group_members(row_groups, gi)
		append(&s.groups, beams_make_group(&s.group_chars, g, .Row, s.config.beam_row_speed_range))
	}
	engine.groups_delete(&row_groups)
	col_groups := engine.get_particles_grouped(
		engine.Particle_Query {
			e.particle_sets,
			e.particles.initial_coord[:len(e.particles)],
			e.canvas,
		},
		engine.PARTICLE_FILTER_ALL_FILLS,
		.Column_L2R,
	)
	for gi in 0 ..< len(col_groups.spans) {
		g := engine.group_members(col_groups, gi)
		append(
			&s.groups,
			beams_make_group(&s.group_chars, g, .Column, s.config.beam_column_speed_range),
		)
	}
	engine.groups_delete(&col_groups)

	s.beam_palette = beam_spectrum
	beam_spectrum = nil
	s.row_symbols, s.row_codes = beams_prepare_lane(
		e,
		s.beam_palette[:],
		s.config.beam_row_symbols[:],
	)
	s.column_symbols, s.column_codes = beams_prepare_lane(
		e,
		s.beam_palette[:],
		s.config.beam_column_symbols[:],
	)

	for gi in 0 ..< len(s.groups) do append(&s.pending, gi)
	reserve(&s.active, len(s.groups))
	engine.random_shuffle(s.pending[:])
}

beams_release_char :: proc(s: ^Beams_State, e: ^engine.Engine, group: ^Beam_Group) #no_bounds_check {
	group.counter -= 1
	next := s.group_chars[group.span.start + group.head]
	group.head += 1
	if s.beam_start_ticks[next] < 0 && s.wipe_start_ticks[next] < 0 do append(&s.appearance_active, next)
	lane_len := len(s.row_symbols) if group.direction == .Row else len(s.column_symbols)
	s.beam_end = max(s.beam_end, s.tick + lane_len * s.config.beam_gradient_frames + 22)
	s.beam_start_ticks[next] = s.tick
	s.beam_modes[next] = group.direction
	engine.set_particle(e, next, engine.Visible(true))
}

beams_update_appearances :: proc(s: ^Beams_State, e: ^engine.Engine) #no_bounds_check {
	write := 0
	for id in s.appearance_active {
		beam_start := s.beam_start_ticks[id]
		if beam_start >= 0 {
			mode := s.beam_modes[id]
			lane_len := len(s.row_symbols) if mode == .Row else len(s.column_symbols)
			beam_ticks := lane_len * s.config.beam_gradient_frames + 22
			age := s.tick - beam_start
			if age < beam_ticks {
				s.appearance_active[write] = id
				write += 1
				palette_ticks := lane_len * s.config.beam_gradient_frames
				if age < palette_ticks {
					if age % s.config.beam_gradient_frames != 0 do continue
				} else if (age - palette_ticks) % 2 != 0 {continue}
				palette_index := age / s.config.beam_gradient_frames
				if palette_index < lane_len {
					symbols := s.row_symbols if mode == .Row else s.column_symbols
					codes := s.row_codes if mode == .Row else s.column_codes
					engine.set_symbol(e, id, symbols[palette_index])
					engine.set_appearance(e, id, codes[palette_index])
				} else {
					engine.set_symbol(e, id, e.particles.initial_symbol[id])
					step := min((age - palette_ticks) / 2, 10)
					engine.set_appearance(e, id, engine.ramp_code(s.fade_ramp, s.style_by_id[id], step))
				}
				continue
			}
		}
		s.beam_start_ticks[id] = -1
		wipe_start := s.wipe_start_ticks[id]
		if wipe_start >= 0 {
			age := s.tick - wipe_start
			if age < 11 * s.config.final_gradient_frames {
				s.appearance_active[write] = id
				write += 1
				if age % s.config.final_gradient_frames != 0 do continue
				engine.set_symbol(e, id, e.particles.initial_symbol[id])
				step := min(age / s.config.final_gradient_frames, 10)
				engine.set_appearance(e, id, engine.ramp_code(s.brighten_ramp, s.style_by_id[id], step))
			} else {s.wipe_start_ticks[id] = -1}
		}
	}
	resize(&s.appearance_active, write)
}

beams_next :: proc(s: ^Beams_State, e: ^engine.Engine) -> bool #no_bounds_check {
	if s.phase == .Complete && s.tick >= s.wipe_end {
		return false
	}
	switch s.phase {
	case .Beams:
		if s.delay == 0 {
			if s.pending_head < len(s.pending) {
				for _ in 0 ..< engine.random_range(1, 6) {
					if s.pending_head == len(s.pending) do break
					append(&s.active, s.pending[s.pending_head])
					s.pending_head += 1
				}
			}
			s.delay = s.config.beam_delay
		} else {
			s.delay -= 1
		}
		// release characters per group speed
		for ai in 0 ..< len(s.active) {
			group := &s.groups[s.active[ai]]
			group.counter += group.speed
			count := int(group.counter)
			if count > 1 {
				for _ in 0 ..< count {
					if group.head >= group.span.len do break
					beams_release_char(s, e, group)
				}
			}
		}
		// drop exhausted groups
		write := 0
		for ai in 0 ..< len(s.active) {
			group := &s.groups[s.active[ai]]
			if group.head < group.span.len {
				s.active[write] = s.active[ai]
				write += 1
			}
		}
		resize(&s.active, write)
		if s.pending_head == len(s.pending) && len(s.active) == 0 && s.tick >= s.beam_end {
			s.phase = .Final_Wipe
		}
	case .Final_Wipe:
		if s.final_wipe_idx < len(s.final_wipe_groups.spans) {
			for _ in 0 ..< s.config.final_wipe_speed {
				if s.final_wipe_idx >= len(s.final_wipe_groups.spans) do break
				g := engine.group_members(s.final_wipe_groups, s.final_wipe_idx)
				s.final_wipe_idx += 1
				for id in g {
					if s.beam_start_ticks[id] < 0 && s.wipe_start_ticks[id] < 0 do append(&s.appearance_active, id)
					s.wipe_end = max(s.wipe_end, s.tick + 11 * s.config.final_gradient_frames)
					s.wipe_start_ticks[id] = s.tick
					engine.set_particle(e, id, engine.Visible(true))
				}
			}
		} else {
			s.phase = .Complete
		}
	case .Complete:
	}
	beams_update_appearances(s, e)
	s.tick += 1
	return true
}
