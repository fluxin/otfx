package effects

import engine "../engine"
import "core:math"
import rand "core:math/rand"
import "core:slice"

import "core:fmt"

// matrix — digital rain; after rain-time seconds the columns fill and resolve
// into the input text.

Matrix_Config :: struct {
	highlight_color:          engine.Color,
	rain_color_gradient:      [dynamic]engine.Color,
	rain_symbols:             [dynamic]string,
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
		..[]string {
			"2",
			"5",
			"9",
			"8",
			"Z",
			"*",
			")",
			":",
			".",
			"\"",
			"=",
			"+",
			"-",
			"¦",
			"|",
			"_",
			"ｦ",
			"ｱ",
			"ｳ",
			"ｴ",
			"ｵ",
			"ｶ",
			"ｷ",
			"ｹ",
			"ｺ",
			"ｻ",
			"ｼ",
			"ｽ",
			"ｾ",
			"ｿ",
			"ﾀ",
			"ﾂ",
			"ﾃ",
			"ﾅ",
			"ﾆ",
			"ﾇ",
			"ﾈ",
			"ﾊ",
			"ﾋ",
			"ﾎ",
			"ﾏ",
			"ﾐ",
			"ﾑ",
			"ﾒ",
			"ﾓ",
			"ﾔ",
			"ﾕ",
			"ﾗ",
			"ﾘ",
			"ﾜ",
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
			if !parse_int_flag(&cfg.rain_time, args, &i, value, has_value) do return false
		case "--symbol-swap-chance":
			if !parse_float_flag(&cfg.symbol_swap_chance, args, &i, value, has_value) do return false
		case "--color-swap-chance":
			if !parse_float_flag(&cfg.color_swap_chance, args, &i, value, has_value) do return false
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
	config:             Matrix_Config,
	columns:            [dynamic]Matrix_Rain_Column,
	column_characters:  [dynamic]engine.Char_Id,
	visible_characters: [dynamic]engine.Char_Id,
	pending_columns:    Matrix_Column_Queue,
	active_columns:     [dynamic]int,
	full_columns:       [dynamic]int,
	resolve_scenes:     [dynamic]engine.Scene,
	resolve_active:     [dynamic]engine.Char_Id,
	resolve_active_ids: [dynamic]u8,
	rain_colors:        [dynamic]engine.Color,
	column_delay:       int,
	resolve_delay:      int,
	final_frame_shown:  bool,
	rain_complete:      bool,
	phase:              Matrix_Phase,
	rain_start:         f64,
}

matrix_column_visible :: proc(
	visible_characters: []engine.Char_Id,
	c: Matrix_Rain_Column,
) -> []engine.Char_Id {
	start := c.characters.start + c.visible_head
	return visible_characters[start:start + c.visible_count]
}

matrix_pending_column_push :: proc(queue: ^Matrix_Column_Queue, ci: int) {
	assert(queue.count < len(queue.items))
	tail := queue.head + queue.count
	if tail >= len(queue.items) do tail -= len(queue.items)
	queue.items[tail] = ci
	queue.count += 1
}

matrix_pending_column_pop :: proc(queue: ^Matrix_Column_Queue) -> int {
	assert(queue.count > 0)
	ci := queue.items[queue.head]
	queue.head += 1
	if queue.head == len(queue.items) do queue.head = 0
	queue.count -= 1
	return ci
}

matrix_setup_column :: proc(
	c: ^Matrix_Rain_Column,
	characters: []engine.Char_Id,
	is_visible: [^]bool,
	current_coords, input_coords: [^]engine.Coord,
	fall_delay_range: Int_Range_Value,
	phase: Matrix_Column_Phase,
) {
	c.pending_head = 0
	c.visible_head = 0
	c.visible_count = 0
	c.full = false
	c.phase = phase
	for id in characters {
		is_visible[id] = false
		current_coords[id] = input_coords[id]
	}
	if phase == .Fill {
		c.base_delay = rand.int_range(
			max(math.floor_div(fall_delay_range.lo, 3), 1),
			max(math.floor_div(fall_delay_range.hi, 3), 1) + 1,
		)
	} else {
		c.base_delay = rand.int_range(fall_delay_range.lo, fall_delay_range.hi + 1)
	}
	c.active_delay = 0
	if phase == .Rain {
		c.length = rand.int_range(max(1, int(f64(len(characters)) * 0.1)), len(characters) + 1)
	} else {
		c.length = len(characters)
	}
	c.hold_time = 0
	if c.length == len(characters) {
		c.hold_time = rand.int_range(20, 46)
	}
}

matrix_trim :: proc(
	c: ^Matrix_Rain_Column,
	visible_characters: []engine.Char_Id,
	rain_colors: []engine.Color,
	chars: ^engine.Character_Storage,
) {
	if c.visible_count == 0 do return
	is_visible := chars.is_visible[:]
	visual_symbols := chars.visual[:]
	popped := visible_characters[c.characters.start + c.visible_head]
	c.visible_head += 1
	c.visible_count -= 1
	is_visible[popped] = false
	if c.visible_count > 1 {
		// fade the new head to a darker tail color
		tail := rain_colors[max(len(rain_colors) - 3, 0):]
		darker := engine.adjust_color_brightness(tail[rand.int_max(len(tail))], 0.65)
		target := visible_characters[c.characters.start + c.visible_head]
		engine.character_set_visual(
			chars,
			target,
			{symbol = visual_symbols[target].symbol, fg = darker},
		)
	}
}

matrix_drop_column :: proc(
	c: ^Matrix_Rain_Column,
	visible_characters: []engine.Char_Id,
	is_visible: [^]bool,
	current_coords: [^]engine.Coord,
	canvas_bottom: int,
) {
	visible := matrix_column_visible(visible_characters, c^)
	write := 0
	for id in visible {
		p := current_coords[id]
		p.row -= 1
		current_coords[id] = p
		if p.row < canvas_bottom {
			is_visible[id] = false
		} else {
			visible[write] = id
			write += 1
		}
	}
	c.visible_count = write
}

matrix_tick_column :: proc(
	c: ^Matrix_Rain_Column,
	characters: []engine.Char_Id,
	visible_characters: []engine.Char_Id,
	rain_symbols: []string,
	rain_colors: []engine.Color,
	highlight_color: engine.Color,
	symbol_swap_chance, color_swap_chance: f64,
	canvas_bottom: int,
	chars: ^engine.Character_Storage,
) {
	is_visible := chars.is_visible[:]
	current_coords := chars.current_coord[:]
	visual_symbols := chars.visual[:]
	visual_fg := chars.visual[:]
	if c.active_delay != 0 {
		c.active_delay -= 1
	} else {
		if c.pending_head < len(characters) {
			next := characters[c.pending_head]
			c.pending_head += 1
			sym := rain_symbols[rand.int_max(len(rain_symbols))]
			engine.character_set_visual(chars, next, {symbol = sym, fg = highlight_color})
			if c.visible_count > 0 {
				prev :=
					visible_characters[c.characters.start + c.visible_head + c.visible_count - 1]
				col := rain_colors[rand.int_max(len(rain_colors))]
				engine.character_set_visual(
					chars,
					prev,
					{symbol = visual_symbols[prev].symbol, fg = col},
				)
			}
			is_visible[next] = true
			visible_characters[c.characters.start + c.visible_head + c.visible_count] = next
			c.visible_count += 1
		} else if c.visible_count > 0 {
			last := visible_characters[c.characters.start + c.visible_head + c.visible_count - 1]
			last_fg := visual_fg[last].fg
			if last_fg != nil && last_fg.? == highlight_color {
				col := rain_colors[rand.int_max(len(rain_colors))]
				engine.character_set_visual(
					chars,
					last,
					{symbol = visual_symbols[last].symbol, fg = col},
				)
			}
			if c.hold_time != 0 {
				c.hold_time -= 1
			} else if c.phase == .Rain {
				if rand.float64() < c.column_drop_chance {
					matrix_drop_column(
						c,
						visible_characters,
						is_visible,
						current_coords,
						canvas_bottom,
					)
				}
				matrix_trim(c, visible_characters, rain_colors, chars)
			}
		}
		if c.visible_count > c.length {
			matrix_trim(c, visible_characters, rain_colors, chars)
		}
		c.active_delay = c.base_delay
	}

	// random symbol/color swaps
	visible := matrix_column_visible(visible_characters, c^)
	for id in visible {
		next_symbol := ""
		next_color: engine.Color
		swap_symbol := rand.float64() < symbol_swap_chance
		swap_color := rand.float64() < color_swap_chance
		if swap_symbol do next_symbol = rain_symbols[rand.int_max(len(rain_symbols))]
		if swap_color do next_color = rain_colors[rand.int_max(len(rain_colors))]
		if !swap_symbol && !swap_color do continue
		current_symbol := visual_symbols[id].symbol
		current_fg := visual_fg[id].fg
		if swap_symbol &&
		   next_symbol == current_symbol &&
		   (!swap_color || (current_fg != nil && current_fg.? == next_color)) {
			continue
		}
		col := swap_color ? next_color : (current_fg != nil ? current_fg.? : highlight_color)
		sym := swap_symbol ? next_symbol : current_symbol
		engine.character_set_visual(chars, id, {symbol = sym, fg = col})
	}
}

matrix_build :: proc(s: ^Matrix_State, e: ^engine.Engine) {
	s.rain_colors = engine.gradient_make(s.config.rain_color_gradient[:], []int{6}, false)

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

	chars := engine.get_characters(
		engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas},
		engine.CHAR_FILTER_INPUT,
		.Top_Bottom_Left_Right,
	)
	defer delete(chars[:])
	s.resolve_scenes = make([dynamic]engine.Scene, len(e.chars))
	s.resolve_active_ids = make([dynamic]u8, len(e.chars))
	input_coords := e.chars.input_coord[:]
	input_symbols := e.chars.input_symbol[:]

	for id in chars {
		c := input_coords[id]
		final := engine.gradient_sample(final_sampler, final_spectrum[:], c)
		g := engine.gradient_make([]engine.Color{s.config.highlight_color, final}, []int{8}, false)
		resolve_scene := &s.resolve_scenes[id]
		for color in g {
			engine.scene_add_frame(
				resolve_scene,
				input_symbols[id],
				s.config.final_gradient_frames,
				color,
				nil,
				false,
			)
		}
		delete(g[:])
	}

	col_groups := engine.get_characters_grouped(
		engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas},
		engine.CHAR_FILTER_ALL_FILLS,
		.Column_L2R,
	)
	reserve(&s.columns, len(col_groups.spans))
	reserve(&s.column_characters, len(col_groups.members))
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
		matrix_setup_column(
			&column,
			g,
			e.chars.is_visible,
			e.chars.current_coord,
			e.chars.input_coord,
			s.config.rain_fall_delay_range,
			.Rain,
		)
		append(&s.columns, column)
	}
	engine.groups_delete(&col_groups)
	s.visible_characters = make([dynamic]engine.Char_Id, len(s.column_characters))
	s.pending_columns.items = make([dynamic]int, len(s.columns))
	for ci in 0 ..< len(s.columns) do s.pending_columns.items[ci] = ci
	s.pending_columns.count = len(s.pending_columns.items)
	reserve(&s.active_columns, len(s.columns))
	reserve(&s.full_columns, len(s.columns))
	rand.shuffle(s.pending_columns.items[:])
	s.rain_start = engine.now_wall(e.wall_start, e.mono_start)
	s.resolve_delay = s.config.resolve_delay
}

matrix_step_resolve_scenes :: proc(s: ^Matrix_State, chars: ^engine.Character_Storage) {
	write := 0
	for id in s.resolve_active {
		visual, complete := engine.step_animation(&s.resolve_scenes[id])
		engine.character_set_visual(chars, id, visual)
		if complete {
			s.resolve_active_ids[id] = 0
		} else {
			s.resolve_active[write] = id
			write += 1
		}
	}
	resize(&s.resolve_active, write)
}

matrix_next :: proc(s: ^Matrix_State, e: ^engine.Engine) -> ([]engine.Char_Id, bool) {
	column_characters := s.column_characters[:]
	visible_characters := s.visible_characters[:]
	columns := s.columns[:]
	rain_symbols := s.config.rain_symbols[:]
	rain_colors := s.rain_colors[:]
	chars := &e.chars
	is_visible := e.chars.is_visible
	input_symbols := e.chars.input_symbol
	current_coords := e.chars.current_coord
	input_coords := e.chars.input_coord
	canvas_bottom := e.canvas.bottom
	if s.phase == .Rain || s.phase == .Fill {
		if s.column_delay == 0 {
			if s.phase == .Rain {
				for _ in 0 ..< rand.int_range(1, 4) {
					if s.pending_columns.count == 0 do break
					append(&s.active_columns, matrix_pending_column_pop(&s.pending_columns))
				}
			} else {
				for s.pending_columns.count > 0 {
					append(&s.active_columns, matrix_pending_column_pop(&s.pending_columns))
				}
			}
			s.column_delay =
				s.phase == .Rain ? rand.int_range(s.config.rain_column_delay_range.lo, s.config.rain_column_delay_range.hi + 1) : 1
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
				rain_colors,
				s.config.highlight_color,
				s.config.symbol_swap_chance,
				s.config.color_swap_chance,
				canvas_bottom,
				chars,
			)
			if column.pending_head == column.characters.len {
				if column.phase == .Fill && !column.full {
					column.full = true
					append(&s.full_columns, ci)
				} else if column.visible_count == 0 {
					phase: Matrix_Column_Phase = s.phase == .Rain ? .Rain : .Fill
					matrix_setup_column(
						column,
						engine.span_slice(column_characters, column.characters),
						is_visible,
						current_coords,
						input_coords,
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
		   engine.now_wall(e.wall_start, e.mono_start) - s.rain_start > f64(s.config.rain_time) {
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
					&columns[ci],
					engine.span_slice(column_characters, columns[ci].characters),
					is_visible,
					current_coords,
					input_coords,
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
				rain_colors,
				s.config.highlight_color,
				s.config.symbol_swap_chance,
				s.config.color_swap_chance,
				canvas_bottom,
				chars,
			)
			if column.visible_count > 0 {
				if s.resolve_delay == 0 {
					for _ in 0 ..< rand.int_range(1, 5) {
						if column.visible_count == 0 do break
						visible := matrix_column_visible(visible_characters, column^)
						idx := rand.int_max(len(visible))
						next := visible[idx]
						visible[idx] = visible[len(visible) - 1]
						column.visible_count -= 1
						if input_symbols[next] != " " {
							scene := &s.resolve_scenes[next]
							engine.character_set_visual(
								chars,
								next,
								engine.scene_first_visual(scene^),
							)
							if s.resolve_active_ids[next] == 0 {
								s.resolve_active_ids[next] = 1
								append(&s.resolve_active, next)
							}
						} else {
							is_visible[next] = false
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
		matrix_step_resolve_scenes(s, chars)
		return nil, true
	}
	if !s.final_frame_shown {
		s.final_frame_shown = true
		matrix_step_resolve_scenes(s, chars)
		return nil, true
	}
	return nil, false
}
