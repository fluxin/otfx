package effects

import "../engine"
import "core:math"
import "core:slice"

import "core:fmt"

// matrix — digital rain; after rain-time seconds the columns fill and resolve
// into the input text.

Matrix_Config :: struct {
	highlight_color:          engine.Color,
	rain_color_gradient:      [dynamic]engine.Color,
	rain_symbols:             [dynamic]rune,
	rain_fall_delay_range:    Int_Range_Value,
	rain_column_delay_range:  Int_Range_Value,
	rain_time:                int,
	symbol_swap_chance:       f64,
	color_swap_chance:        f64,
	resolve_delay:            int,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_frames:    int,
	final_gradient_direction: engine.Gradient_Direction,
}

matrix_config_default :: proc() -> Matrix_Config {
	cfg := Matrix_Config {
		highlight_color          = engine.Color{0xdb, 0xff, 0xdb},
		rain_fall_delay_range    = {2, 15},
		rain_column_delay_range  = {3, 9},
		rain_time                = 15,
		symbol_swap_chance       = 0.005,
		color_swap_chance        = 0.001,
		resolve_delay            = 3,
		final_gradient_frames    = 3,
		final_gradient_direction = .Radial,
	}
	append(
		&cfg.rain_color_gradient,
		..[]engine.Color{engine.Color{0x92, 0xbe, 0x92}, engine.Color{0x18, 0x53, 0x18}},
	)
	append(
		&cfg.rain_symbols,
		..[]rune {
			'2',
			'5',
			'9',
			'8',
			'Z',
			'*',
			')',
			':',
			'.',
			'"',
			'=',
			'+',
			'-',
			'¦',
			'|',
			'_',
			'ｦ',
			'ｱ',
			'ｳ',
			'ｴ',
			'ｵ',
			'ｶ',
			'ｷ',
			'ｹ',
			'ｺ',
			'ｻ',
			'ｼ',
			'ｽ',
			'ｾ',
			'ｿ',
			'ﾀ',
			'ﾂ',
			'ﾃ',
			'ﾅ',
			'ﾆ',
			'ﾇ',
			'ﾈ',
			'ﾊ',
			'ﾋ',
			'ﾎ',
			'ﾏ',
			'ﾐ',
			'ﾑ',
			'ﾒ',
			'ﾓ',
			'ﾔ',
			'ﾕ',
			'ﾗ',
			'ﾘ',
			'ﾜ',
		},
	)
	append(
		&cfg.final_gradient_stops,
		..[]engine.Color{engine.Color{0x92, 0xbe, 0x92}, engine.Color{0x33, 0x6b, 0x33}},
	)
	append(&cfg.final_gradient_steps, 12)
	return cfg
}

matrix_parse :: proc(cfg: ^Matrix_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--highlight-color":
			if !parse_color_flag(&cfg.highlight_color, args, &i, value, has_value) do return false
		case "--rain-color-gradient":
			if !parse_colors_flag(&cfg.rain_color_gradient, args, &i, value, has_value) do return false
		case "--rain-symbols":
			if !parse_symbols_flag(&cfg.rain_symbols, args, &i, value, has_value) do return false
		case "--rain-fall-delay-range":
			if !parse_int_range_flag(&cfg.rain_fall_delay_range, args, &i, value, has_value) do return false
		case "--rain-column-delay-range":
			if !parse_int_range_flag(&cfg.rain_column_delay_range, args, &i, value, has_value) do return false
		case "--rain-time":
			if !parse_int_flag(&cfg.rain_time, args, &i, value, has_value) || cfg.rain_time <= 0 do return false
		case "--symbol-swap-chance":
			if !parse_float_flag(&cfg.symbol_swap_chance, args, &i, value, has_value) || cfg.symbol_swap_chance < 0 || cfg.symbol_swap_chance > 1 do return false
		case "--color-swap-chance":
			if !parse_float_flag(&cfg.color_swap_chance, args, &i, value, has_value) || cfg.color_swap_chance < 0 || cfg.color_swap_chance > 1 do return false
		case "--resolve-delay":
			if !parse_int_flag(&cfg.resolve_delay, args, &i, value, has_value) do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-frames":
			if !parse_int_flag(&cfg.final_gradient_frames, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown matrix option: ", name)
			return false
		}
	}
	return true
}

Matrix_Column_Phase :: enum {
	Rain,
	Fill,
}

Matrix_Rain_Column :: struct {
	characters:         engine.Span,
	pending_head:       int,
	visible_head:       int,
	visible_count:      int,
	phase:              Matrix_Column_Phase,
	full:               bool,
	column_drop_chance: f64,
	base_delay:         int,
	active_delay:       int,
	length:             int,
	hold_time:          int,
}

Matrix_Phase :: enum {
	Rain,
	Fill,
	Resolve,
}

Matrix_Column_Queue :: struct {
	items: [dynamic]int,
	head:  int,
	count: int,
}

Matrix_State :: struct {
	config:               Matrix_Config,
	columns:              [dynamic]Matrix_Rain_Column,
	column_characters:    [dynamic]engine.Particle_Id,
	visible_characters:   [dynamic]engine.Particle_Id,
	pending_columns:      Matrix_Column_Queue,
	active_columns:       [dynamic]int,
	full_columns:         [dynamic]int,
	resolve_ramp:         engine.Appearance_Ramp,
	resolve_fade_index:   []int,
	resolvable_kind:      []u8, // 0 = non-resolvable fill, 1 = 9-step fade, 2 = 1-step uncolored dynamic
	resolve_ticks:        []int,
	resolve_active:       [dynamic]engine.Particle_Id,
	resolve_active_ids:   []u8,
	rain_colors:          [dynamic]engine.Color,
	rain_codes:           [dynamic]engine.Appearance_Id,
	tail_codes:           [dynamic]engine.Appearance_Id,
	highlight_code:       engine.Appearance_Id,
	column_delay:         int,
	resolve_delay:        int,
	final_frame_shown:    bool,
	rain_complete:        bool,
	phase:                Matrix_Phase,
	rain_start:           f64,
	color_handling:       engine.Existing_Color_Handling,
}

matrix_column_visible :: #force_inline proc(
	visible_characters: []engine.Particle_Id,
	c: Matrix_Rain_Column,
) -> []engine.Particle_Id #no_bounds_check {
	start := c.characters.start + c.visible_head
	return visible_characters[start:start + c.visible_count]
}

matrix_pending_column_push :: #force_inline proc(queue: ^Matrix_Column_Queue, ci: int) #no_bounds_check {
	assert(queue.count < len(queue.items))
	tail := queue.head + queue.count
	if tail >= len(queue.items) do tail -= len(queue.items)
	queue.items[tail] = ci
	queue.count += 1
}

matrix_pending_column_pop :: #force_inline proc(queue: ^Matrix_Column_Queue) -> int #no_bounds_check {
	assert(queue.count > 0)
	ci := queue.items[queue.head]
	queue.head += 1
	if queue.head == len(queue.items) do queue.head = 0
	queue.count -= 1
	return ci
}

matrix_setup_column :: proc(
	e: ^engine.Engine,
	c: ^Matrix_Rain_Column,
	characters: []engine.Particle_Id,
	fall_delay_range: Int_Range_Value,
	phase: Matrix_Column_Phase,
) #no_bounds_check {
	c.pending_head = 0
	c.visible_head = 0
	c.visible_count = 0
	c.full = false
	c.phase = phase
	for id in characters {
		engine.set_placement(
			e,
			id,
			e.particles.initial_coord[id],
			false,
			e.particles.layer[id],
		)
	}
	if phase == .Fill {
		c.base_delay = engine.random_range(
			max(math.floor_div(fall_delay_range.lo, 3), 1),
			max(math.floor_div(fall_delay_range.hi, 3), 1) + 1,
		)
	} else {
		c.base_delay = engine.random_range(fall_delay_range.lo, fall_delay_range.hi + 1)
	}
	c.active_delay = 0
	if phase == .Rain {
		c.length = engine.random_range(max(1, int(f64(len(characters)) * 0.1)), len(characters) + 1)
	} else {
		c.length = len(characters)
	}
	c.hold_time = 0
	if c.length == len(characters) {
		c.hold_time = engine.random_range(20, 46)
	}
}

matrix_trim :: proc(
	c: ^Matrix_Rain_Column,
	visible_characters: []engine.Particle_Id,
	tail_codes: []engine.Appearance_Id,
	e: ^engine.Engine,
) #no_bounds_check {
	if c.visible_count == 0 do return

	popped := visible_characters[c.characters.start + c.visible_head]
	c.visible_head += 1
	c.visible_count -= 1
	engine.set_visible(e, popped, false)
	if c.visible_count > 1 {
		// fade the new head to a darker tail color
		darker_code := tail_codes[engine.random_below(len(tail_codes))]
		target := visible_characters[c.characters.start + c.visible_head]
		engine.set_appearance(e, target, darker_code)
	}
}

matrix_drop_column :: proc(
	e: ^engine.Engine,
	c: ^Matrix_Rain_Column,
	visible_characters: []engine.Particle_Id,
	canvas_bottom: int,
) #no_bounds_check {
	visible := matrix_column_visible(visible_characters, c^)
	write := 0
	for id in visible {
		p := e.particles.current_coord[id]
		p.row -= 1
		engine.set_position(e, id, p)
		if p.row < canvas_bottom {
			engine.set_visible(e, id, false)
		} else {
			visible[write] = id
			write += 1
		}
	}
	c.visible_count = write
}

matrix_tick_column :: proc(
	c: ^Matrix_Rain_Column,
	characters: []engine.Particle_Id,
	visible_characters: []engine.Particle_Id,
	rain_symbols: []rune,
	rain_codes: []engine.Appearance_Id,
	tail_codes: []engine.Appearance_Id,
	highlight_color: engine.Color,
	highlight_code: engine.Appearance_Id,
	symbol_swap_chance, color_swap_chance: f64,
	canvas_bottom: int,
	e: ^engine.Engine,
) #no_bounds_check {
	if c.active_delay != 0 {
		c.active_delay -= 1
	} else {
		if c.pending_head < len(characters) {
			next := characters[c.pending_head]
			c.pending_head += 1
			sym := rain_symbols[engine.random_below(len(rain_symbols))]
			engine.set_symbol(e, next, sym)
			engine.set_appearance(e, next, highlight_code)
			if c.visible_count > 0 {
				prev :=
					visible_characters[c.characters.start + c.visible_head + c.visible_count - 1]
				code := rain_codes[engine.random_below(len(rain_codes))]
				engine.set_appearance(e, prev, code)
			}
			engine.set_visible(e, next, true)
			visible_characters[c.characters.start + c.visible_head + c.visible_count] = next
			c.visible_count += 1
		} else if c.visible_count > 0 {
			last := visible_characters[c.characters.start + c.visible_head + c.visible_count - 1]
			last_fg := engine.get_appearance(e, last).colors.fg
			if last_fg != nil && last_fg.? == highlight_color {
				code := rain_codes[engine.random_below(len(rain_codes))]
				engine.set_appearance(e, last, code)
			}
			if c.hold_time != 0 {
				c.hold_time -= 1
			} else if c.phase == .Rain {
				if engine.random_float() < c.column_drop_chance {
					matrix_drop_column(e, c, visible_characters, canvas_bottom)
				}
				matrix_trim(c, visible_characters, tail_codes, e)
			}
		}
		if c.visible_count > c.length {
			matrix_trim(c, visible_characters, tail_codes, e)
		}
		c.active_delay = c.base_delay
	}

	// random symbol/color swaps
	visible := matrix_column_visible(visible_characters, c^)
	for id in visible {
		next_symbol: rune
		next_code: engine.Appearance_Id
		swap_symbol := engine.random_float() < symbol_swap_chance
		swap_color := engine.random_float() < color_swap_chance
		if swap_symbol do next_symbol = rain_symbols[engine.random_below(len(rain_symbols))]
		if swap_color do next_code = rain_codes[engine.random_below(len(rain_codes))]
		if !swap_symbol && !swap_color do continue
		if swap_symbol do engine.set_symbol(e, id, next_symbol)
		if swap_color do engine.set_appearance(e, id, next_code)
	}
}

matrix_build :: proc(s: ^Matrix_State, e: ^engine.Engine) {
	s.rain_colors = engine.gradient_make(s.config.rain_color_gradient[:], []int{6}, false)
	s.highlight_code = engine.prepare_appearance(e, {colors = {fg = s.config.highlight_color}})
	s.rain_codes = make([dynamic]engine.Appearance_Id, len(s.rain_colors))
	for c, i in s.rain_colors {
		s.rain_codes[i] = engine.prepare_appearance(e, {colors = {fg = c}})
	}
	tail_slice := s.rain_colors[max(len(s.rain_colors) - 3, 0):]
	s.tail_codes = make([dynamic]engine.Appearance_Id, len(tail_slice))
	for c, i in tail_slice {
		darker := engine.adjust_color_brightness(c, 0.65)
		s.tail_codes[i] = engine.prepare_appearance(e, {colors = {fg = darker}})
	}

	final_spectrum := engine.gradient_make(
		s.config.final_gradient_stops[:],
		s.config.final_gradient_steps[:],
		false,
		context.temp_allocator,
	)
	defer delete(final_spectrum)
	final_sampler := engine.gradient_sampler(
		e.canvas.text_bottom,
		e.canvas.text_top,
		e.canvas.text_left,
		e.canvas.text_right,
		s.config.final_gradient_direction,
	)

	s.color_handling = e.cfg.existing_color_handling
	storage_len := len(e.particles)
	s.resolve_fade_index = make([]int, storage_len)
	s.resolvable_kind = make([]u8, storage_len)
	s.resolve_ticks = make([]int, storage_len)
	s.resolve_active_ids = make([]u8, storage_len)

	resolve_tweens: [dynamic]engine.Tween(engine.Appearance)
	defer delete(resolve_tweens)
	resolve_ids: [dynamic]engine.Particle_Id
	defer delete(resolve_ids)
	hl := s.config.highlight_color
	for idx in 0 ..< storage_len {
		id := engine.Particle_Id(idx)
		init_style := engine.get_initial_appearance(e, id)
		has_style := init_style.colors.fg != nil || init_style.colors.bg != nil
		if e.particles.initial_symbol[id] == ' ' && !has_style do continue
		s.resolvable_kind[id] = s.color_handling == .Dynamic && !has_style ? 2 : 1
		append(&resolve_ids, id)
		if s.color_handling == .Dynamic {
			append(
				&resolve_tweens,
				engine.Tween(engine.Appearance) {
					from = {colors = {hl, hl}},
					to   = {colors = init_style.colors},
				},
			)
		} else {
			final := engine.gradient_sample(final_sampler, final_spectrum[:], e.particles.initial_coord[id])
			append(
				&resolve_tweens,
				engine.Tween(engine.Appearance) {
					from = {colors = {fg = hl}},
					to   = {colors = {fg = final}},
				},
			)
		}
	}
	if len(resolve_tweens) > 0 {
		unique_tweens, indices := engine.group_values(resolve_tweens[:])
		defer delete(unique_tweens)
		defer delete(indices)
		s.resolve_ramp = engine.ramp_make(e, unique_tweens[:], 8)
		for id, k in resolve_ids do s.resolve_fade_index[id] = indices[k]
	}

	col_groups := engine.get_particles_grouped(
		engine.Particle_Query {
			e.particle_sets,
			e.particles.initial_coord[:len(e.particles)],
			e.canvas,
		},
		engine.PARTICLE_FILTER_ALL_FILLS,
		.Column_L2R,
	)
	reserve(&s.columns, len(col_groups.spans))
	reserve(&s.column_characters, len(col_groups.spans) > 0 ? len(col_groups.members) : 0)
	for gi in 0 ..< len(col_groups.spans) {
		g := engine.group_members(col_groups, gi)
		slice.reverse(g)
		column: Matrix_Rain_Column
		column.characters = {
			start = len(s.column_characters),
			len   = len(g),
		}
		append(&s.column_characters, ..g)
		column.column_drop_chance = 0.08
		// RainColumn.__init__ in the reference sets the first run's pending
		// characters, delay, and visible trail length before it is activated.
		matrix_setup_column(e, &column, g, s.config.rain_fall_delay_range, .Rain)
		append(&s.columns, column)
	}
	engine.groups_delete(&col_groups)
	s.visible_characters = make([dynamic]engine.Particle_Id, len(s.column_characters))
	s.pending_columns.items = make([dynamic]int, len(s.columns))
	for ci in 0 ..< len(s.columns) do s.pending_columns.items[ci] = ci
	s.pending_columns.count = len(s.pending_columns.items)
	reserve(&s.active_columns, len(s.columns))
	reserve(&s.full_columns, len(s.columns))
	reserve(&s.resolve_active, len(resolve_ids))
	engine.random_shuffle(s.pending_columns.items[:])
	s.rain_start = engine.elapsed_seconds(e)
	s.resolve_delay = s.config.resolve_delay
}

matrix_step_resolve :: proc(s: ^Matrix_State, e: ^engine.Engine) #no_bounds_check {
	write := 0
	for id in s.resolve_active {
		tick := s.resolve_ticks[id]
		if tick % s.config.final_gradient_frames == 0 {
			step := min(tick / s.config.final_gradient_frames, 8)
			engine.set_symbol(e, id, e.particles.initial_symbol[id])
			engine.set_appearance(e, id, engine.ramp_code(s.resolve_ramp, s.resolve_fade_index[id], step))
		}
		tick += 1
		limit := s.resolvable_kind[id] == 2 ? s.config.final_gradient_frames : 9 * s.config.final_gradient_frames
		if tick == limit {
			s.resolve_active_ids[id] = 0
		} else {
			s.resolve_ticks[id] = tick
			s.resolve_active[write] = id
			write += 1
		}
	}
	resize(&s.resolve_active, write)
}

matrix_next :: proc(s: ^Matrix_State, e: ^engine.Engine) -> bool #no_bounds_check {
	column_characters := s.column_characters[:]
	visible_characters := s.visible_characters[:]
	columns := s.columns[:]
	rain_symbols := s.config.rain_symbols[:]
	rain_codes := s.rain_codes[:]
	tail_codes := s.tail_codes[:]
	canvas_bottom := e.canvas.bottom
	if s.phase == .Rain || s.phase == .Fill {
		if s.column_delay == 0 {
			if s.phase == .Rain {
				for _ in 0 ..< engine.random_range(1, 4) {
					if s.pending_columns.count == 0 do break
					append(&s.active_columns, matrix_pending_column_pop(&s.pending_columns))
				}
			} else {
				for s.pending_columns.count > 0 {
					append(&s.active_columns, matrix_pending_column_pop(&s.pending_columns))
				}
			}
			s.column_delay =
				s.phase == .Rain ? engine.random_range(s.config.rain_column_delay_range.lo, s.config.rain_column_delay_range.hi + 1) : 1
		} else {
			s.column_delay -= 1
		}

		for ci in s.active_columns {
			column := &columns[ci]
			matrix_tick_column(
				column,
				engine.span_slice(column_characters, column.characters),
				visible_characters,
				rain_symbols,
				rain_codes,
				tail_codes,
				s.config.highlight_color,
				s.highlight_code,
				s.config.symbol_swap_chance,
				s.config.color_swap_chance,
				canvas_bottom,
				e,
			)
			if column.pending_head == column.characters.len {
				if column.phase == .Fill && !column.full {
					column.full = true
					append(&s.full_columns, ci)
				} else if column.visible_count == 0 {
					phase: Matrix_Column_Phase = s.phase == .Rain ? .Rain : .Fill
					matrix_setup_column(
						e,
						column,
						engine.span_slice(column_characters, column.characters),
						s.config.rain_fall_delay_range,
						phase,
					)
					matrix_pending_column_push(&s.pending_columns, ci)
				}
			}
		}
		// prune empty active columns
		write := 0
		for ci in s.active_columns {
			if columns[ci].visible_count > 0 {
				s.active_columns[write] = ci
				write += 1
			}
		}
		resize(&s.active_columns, write)

		if s.phase == .Fill && s.pending_columns.count == 0 {
			all_done := true
			for ci in s.active_columns {
				if columns[ci].pending_head < columns[ci].characters.len ||
				   columns[ci].phase != .Fill {
					all_done = false
					break
				}
			}
			if all_done {
				s.phase = .Resolve
				clear(&s.active_columns)
			}
		}

		if s.phase == .Rain &&
		   s.config.rain_time > 0 &&
		   engine.elapsed_seconds(e) - s.rain_start > f64(s.config.rain_time) {
			s.rain_complete = true
			s.phase = .Fill
			for ci in s.active_columns {
				columns[ci].hold_time = 0
				columns[ci].column_drop_chance = 1.0
			}
			pending_index := s.pending_columns.head
			for _ in 0 ..< s.pending_columns.count {
				ci := s.pending_columns.items[pending_index]
				matrix_setup_column(
					e,
					&columns[ci],
					engine.span_slice(column_characters, columns[ci].characters),
					s.config.rain_fall_delay_range,
					.Fill,
				)
				pending_index += 1
				if pending_index == len(s.pending_columns.items) do pending_index = 0
			}
		}
	} else if s.phase == .Resolve {
		for ci in s.full_columns {
			column := &columns[ci]
			matrix_tick_column(
				column,
				engine.span_slice(column_characters, column.characters),
				visible_characters,
				rain_symbols,
				rain_codes,
				tail_codes,
				s.config.highlight_color,
				s.highlight_code,
				s.config.symbol_swap_chance,
				s.config.color_swap_chance,
				canvas_bottom,
				e,
			)
			if column.visible_count > 0 {
				if s.resolve_delay == 0 {
					for _ in 0 ..< engine.random_range(1, 5) {
						if column.visible_count == 0 do break
						visible := matrix_column_visible(visible_characters, column^)
						idx := engine.random_below(len(visible))
						next := visible[idx]
						visible[idx] = visible[len(visible) - 1]
						column.visible_count -= 1
						if s.resolvable_kind[next] != 0 {
							if s.resolve_active_ids[next] == 0 {
								s.resolve_active_ids[next] = 1
								s.resolve_ticks[next] = 0
								engine.set_symbol(e, next, e.particles.initial_symbol[next])
								engine.set_appearance(e, next, s.highlight_code)
								append(&s.resolve_active, next)
							}
						} else {
							engine.set_visible(e, next, false)
						}
					}
					s.resolve_delay = s.config.resolve_delay
				} else {
					s.resolve_delay -= 1
				}
			}
		}
		write := 0
		for ci in s.full_columns {
			if columns[ci].visible_count > 0 {
				s.full_columns[write] = ci
				write += 1
			}
		}
		resize(&s.full_columns, write)
	}

	if len(s.full_columns) > 0 ||
	   len(s.active_columns) > 0 ||
	   len(s.resolve_active) > 0 ||
	   s.pending_columns.count > 0 ||
	   !s.rain_complete {
		matrix_step_resolve(s, e)
		return true
	}
	if !s.final_frame_shown {
		s.final_frame_shown = true
		matrix_step_resolve(s, e)
		return true
	}
	return false
}
