package effects

import "../engine"

import "core:fmt"
import "core:math/ease"
import "core:math/rand"
import "core:time"

// Thunderstorm keeps its weather as dense particle rows.  It deliberately does
// not use the reference event graph: a row's start tick and phase describe all
// state needed to update it, while active/free lists make reclamation O(1).

Thunderstorm_Config :: struct {
	lightning_color:          engine.Color,
	glowing_text_color:       engine.Color,
	text_glow_time:           int,
	raindrop_symbols:         [dynamic]string,
	spark_symbols:            [dynamic]string,
	spark_glow_color:         engine.Color,
	spark_glow_time:          int,
	storm_time:               int,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_frames:    int,
	final_gradient_direction: engine.Gradient_Direction,
}

thunderstorm_config_default :: proc() -> Thunderstorm_Config {
	cfg := Thunderstorm_Config {
		lightning_color          = engine.Color{0x68, 0xA3, 0xE8},
		glowing_text_color       = engine.Color{0xEF, 0x54, 0x11},
		text_glow_time           = 6,
		spark_glow_color         = engine.Color{0xFF, 0x4D, 0x00},
		spark_glow_time          = 18,
		storm_time               = 12,
		final_gradient_frames    = 3,
		final_gradient_direction = .Vertical,
	}
	append(&cfg.raindrop_symbols, "\\", ".", ",")
	append(&cfg.spark_symbols, "*", ".", "'")
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

thunderstorm_parse :: proc(cfg: ^Thunderstorm_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--lightning-color":
			if !parse_color_flag(&cfg.lightning_color, args, &i, value, has_value) do return false
		case "--glowing-text-color":
			if !parse_color_flag(&cfg.glowing_text_color, args, &i, value, has_value) do return false
		case "--text-glow-time":
			if !parse_int_flag(&cfg.text_glow_time, args, &i, value, has_value) || cfg.text_glow_time <= 0 do return false
		case "--raindrop-symbols":
			if !parse_symbols_flag(&cfg.raindrop_symbols, args, &i, value, has_value) || len(cfg.raindrop_symbols) == 0 do return false
		case "--spark-symbols":
			if !parse_symbols_flag(&cfg.spark_symbols, args, &i, value, has_value) || len(cfg.spark_symbols) == 0 do return false
		case "--spark-glow-color":
			if !parse_color_flag(&cfg.spark_glow_color, args, &i, value, has_value) do return false
		case "--spark-glow-time":
			if !parse_int_flag(&cfg.spark_glow_time, args, &i, value, has_value) || cfg.spark_glow_time <= 0 do return false
		case "--storm-time":
			if !parse_int_flag(&cfg.storm_time, args, &i, value, has_value) || cfg.storm_time <= 0 do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-frames":
			if !parse_int_flag(&cfg.final_gradient_frames, args, &i, value, has_value) || cfg.final_gradient_frames <= 0 do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown thunderstorm option: ", name)
			return false
		}
	}
	return true
}

Thunderstorm_Phase :: enum {
	Prestorm,
	Storm,
	Poststorm,
}

Thunderstorm_State :: struct {
	config:              Thunderstorm_Config,
	characters:          [dynamic]engine.Char_Id,
	final_colors:        [dynamic]engine.Color,
	storm_colors:        [dynamic]engine.Color,
	visible_bg:          [dynamic]Maybe(engine.Color),
	storm_bg:            [dynamic]Maybe(engine.Color),
	input_slot_by_id:    [dynamic]int,
	input_at_cell:       [dynamic]i32,
	glow_starts:         [dynamic]int,
	glow_active:         [dynamic]int,
	render_ids:          [dynamic]engine.Char_Id,

	// Rain has a strict geometric maximum: at most six drops every two ticks;
	// with minimum speed 0.5 and horizontal drift at most height + 1, a drop
	// lives for <= 3*(height+1) ticks.  9*(height+1)+6 rows covers every live
	// batch with no test-sized cap or per-frame allocation.
	rain_ids:            [dynamic]engine.Char_Id,
	rain_starts:         [dynamic]int,
	rain_origins:        [dynamic]engine.Coord,
	rain_targets:        [dynamic]engine.Coord,
	rain_steps:          [dynamic]int,
	rain_active:         [dynamic]int,
	rain_free:           [dynamic]int,
	rain_delay:          int,

	// The main bolt can branch once from every row. A branch beginning at row r
	// contains at most r rows, so height * (height + 3) / 2 is the exact
	// geometric maximum for one strike (main trunk plus every possible arm).
	// Sparks can overlap across stochastic strikes, so that pool grows only to
	// live demand.
	strike_ids:          [dynamic]engine.Char_Id,
	strike_pending:      [dynamic]engine.Char_Id,
	strike_pending_head: int,
	strike_delay:        int,
	strike_flash_age:    int,
	strike_live:         bool,
	spark_ids:           [dynamic]engine.Char_Id,
	spark_starts:        [dynamic]int,
	spark_origins:       [dynamic]engine.Coord,
	spark_controls:      [dynamic]engine.Coord,
	spark_targets:       [dynamic]engine.Coord,
	spark_steps:         [dynamic]int,
	spark_active:        [dynamic]int,
	spark_free:          [dynamic]int,
	phase:               Thunderstorm_Phase,
	phase_tick:          int,
	storm_started:       time.Tick,
	tick:                int,
	color_handling:      engine.Existing_Color_Handling,
}

thunderstorm_cell_index :: #force_inline proc(c: engine.Canvas, p: engine.Coord) -> int {
	return (p.row - c.bottom) * c.width + (p.column - c.left)
}

thunderstorm_take_rain :: proc(s: ^Thunderstorm_State) -> int {
	last := len(s.rain_free) - 1
	assert(last >= 0)
	slot := s.rain_free[last]
	resize(&s.rain_free, last)
	return slot
}

thunderstorm_take_spark :: proc(s: ^Thunderstorm_State, e: ^engine.Engine) -> int {
	if len(s.spark_free) > 0 {
		last := len(s.spark_free) - 1
		slot := s.spark_free[last]
		resize(&s.spark_free, last)
		return slot
	}
	// Eighteen is a natural one-impact batch, not a ceiling. Additional rows
	// are created only when separate strikes overlap before earlier sparks cool.
	id := engine.add_character(e, "*", engine.coord(0, 0))
	e.chars.layer[id] = 2
	e.chars.is_visible[id] = false
	append(&s.spark_ids, id)
	append(&s.spark_starts, -1)
	append(&s.spark_origins, engine.coord(0, 0))
	append(&s.spark_controls, engine.coord(0, 0))
	append(&s.spark_targets, engine.coord(0, 0))
	append(&s.spark_steps, 1)
	return len(s.spark_ids) - 1
}

thunderstorm_build :: proc(s: ^Thunderstorm_State, e: ^engine.Engine) {
	s.color_handling = e.cfg.existing_color_handling
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
	s.storm_colors = make([dynamic]engine.Color, n)
	s.visible_bg = make([dynamic]Maybe(engine.Color), n)
	s.storm_bg = make([dynamic]Maybe(engine.Color), n)
	s.glow_starts = make([dynamic]int, n)
	s.input_slot_by_id = make([dynamic]int, len(e.chars))
	for i in 0 ..< len(s.input_slot_by_id) do s.input_slot_by_id[i] = -1
	s.input_at_cell = make([dynamic]i32, e.canvas.width * e.canvas.height)
	for i in 0 ..< len(s.input_at_cell) do s.input_at_cell[i] = -1

	input_coords := e.chars.input_coord
	visual_fg := e.chars.visual
	visible := e.chars.is_visible
	for id, i in s.characters {
		p := input_coords[id]
		final := engine.gradient_sample(sampler, spectrum[:], p)
		if s.color_handling == .Dynamic {
			style := e.chars.input_style[id]
			final = engine.Color{0x80, 0x80, 0x80}
			if fg, ok := style.fg.?; ok do final = fg
			s.visible_bg[i] = style.bg
			if bg, ok := style.bg.?; ok do s.storm_bg[i] = engine.adjust_color_brightness(bg, 0.5)
		}
		s.final_colors[i] = final
		s.storm_colors[i] = engine.adjust_color_brightness(final, 0.5)
		s.glow_starts[i] = -1
		s.input_slot_by_id[id] = i
		s.input_at_cell[thunderstorm_cell_index(e.canvas, p)] = i32(id)
		visual_fg[id].fg = final
		visual_fg[id].bg = s.visible_bg[i]
		visible[id] = true
	}
	// Input glyphs are the permanent render prefix. Weather rows append only
	// while live, keeping the painter pass proportional to visible particles.
	reserve(
		&s.render_ids,
		n + 9 * (e.canvas.height + 1) + 6 + e.canvas.height * (e.canvas.height + 3) / 2 + 18,
	)
	append(&s.render_ids, ..s.characters[:])

	// See the strict bound documented on the state fields. Allocate every rain
	// row before frame processing; its free list is the compact reusable pool.
	rain_capacity := 9 * (e.canvas.height + 1) + 6
	reserve(&s.rain_ids, rain_capacity)
	reserve(&s.rain_starts, rain_capacity)
	reserve(&s.rain_origins, rain_capacity)
	reserve(&s.rain_targets, rain_capacity)
	reserve(&s.rain_steps, rain_capacity)
	reserve(&s.rain_free, rain_capacity)
	for slot in 0 ..< rain_capacity {
		id := engine.add_character(e, ".", engine.coord(0, 0))
		e.chars.layer[id] = 1
		e.chars.is_visible[id] = false
		append(&s.rain_ids, id)
		append(&s.rain_starts, -1)
		append(&s.rain_origins, engine.coord(0, 0))
		append(&s.rain_targets, engine.coord(0, 0))
		append(&s.rain_steps, 1)
		append(&s.rain_free, slot)
	}

	strike_capacity := e.canvas.height * (e.canvas.height + 3) / 2
	reserve(&s.strike_ids, strike_capacity)
	for _ in 0 ..< strike_capacity {
		id := engine.add_character(e, "|", engine.coord(0, 0))
		e.chars.layer[id] = 2
		e.chars.is_visible[id] = false
		append(&s.strike_ids, id)
	}
	// One natural spark burst is reserved. It remains growable for live overlap.
	reserve(&s.spark_ids, 18)
	reserve(&s.spark_starts, 18)
	reserve(&s.spark_origins, 18)
	reserve(&s.spark_controls, 18)
	reserve(&s.spark_targets, 18)
	reserve(&s.spark_steps, 18)
	reserve(&s.spark_free, 18)
}

thunderstorm_spawn_rain :: proc(
	s: ^Thunderstorm_State,
	chars: ^engine.Character_Storage,
	canvas: engine.Canvas,
) {
	if s.rain_delay > 0 {
		s.rain_delay -= 1
		return
	}
	count := rand.int_range(1, 7)
	for _ in 0 ..< count {
		slot := thunderstorm_take_rain(s)
		origin := engine.coord(
			rand.int_range(1 - canvas.top, canvas.right + 1) - 1,
			canvas.top + 1,
		)
		target := engine.coord(origin.column + canvas.top + 1, canvas.bottom - 1)
		s.rain_starts[slot] = s.tick
		s.rain_origins[slot], s.rain_targets[slot] = origin, target
		s.rain_steps[slot] = max(
			engine.round_half_even(
				engine.line_length(origin, target, true) / rand.float64_range(0.5, 1.5),
			),
			1,
		)
		id := s.rain_ids[slot]
		chars.current_coord[id] = origin
		chars.visual[id].symbol =
			s.config.raindrop_symbols[rand.int_max(len(s.config.raindrop_symbols))]
		chars.visual[id].fg = engine.Color{0xAA, 0xAA, 0xFF}
		chars.is_visible[id] = true
		append(&s.rain_active, slot)
	}
	s.rain_delay = rand.int_range(1, 8)
}

thunderstorm_append_strike_segment :: proc(
	s: ^Thunderstorm_State,
	chars: ^engine.Character_Storage,
	column, row: int,
	symbol: string,
) {
	segment := len(s.strike_pending)
	assert(segment < len(s.strike_ids))
	id := s.strike_ids[segment]
	chars.current_coord[id] = engine.coord(column, row)
	chars.visual[id].symbol = symbol
	chars.visual[id].fg = s.config.lightning_color
	chars.is_visible[id] = false
	append(&s.strike_pending, id)
}

// A side arm is a full descending bolt whose first segment departs left or
// right from its parent. It cannot branch again, matching the reference's
// branch-neighbor guard while keeping the strike as flat SoA-backed rows.
thunderstorm_append_strike_branch :: proc(
	s: ^Thunderstorm_State,
	chars: ^engine.Character_Storage,
	canvas: engine.Canvas,
	column, row: int,
) {
	branch_column, branch_row := column, row
	first := true
	for branch_row >= canvas.bottom {
		symbol: string
		if first {
			right := rand.int_max(2) != 0
			symbol = right ? "\\" : "/"
			first = false
		} else {
			symbol_index := rand.int_max(3)
			symbol = symbol_index == 0 ? "\\" : symbol_index == 1 ? "/" : "|"
		}
		thunderstorm_append_strike_segment(s, chars, branch_column, branch_row, symbol)
		branch_row -= 1
		if symbol == "\\" {
			branch_column += 1
		} else if symbol == "/" {
			branch_column -= 1
		}
	}
}

thunderstorm_begin_strike :: proc(
	s: ^Thunderstorm_State,
	chars: ^engine.Character_Storage,
	canvas: engine.Canvas,
) {
	clear(&s.strike_pending)
	s.strike_pending_head, s.strike_delay, s.strike_flash_age = 0, 0, -1
	column := rand.int_range(canvas.left, canvas.right + 1)
	row := canvas.top
	for row >= canvas.bottom {
		symbol_index := rand.int_max(3)
		symbol := symbol_index == 0 ? "\\" : symbol_index == 1 ? "/" : "|"
		thunderstorm_append_strike_segment(s, chars, column, row, symbol)
		// The reference draws this random value for every trunk segment and
		// inserts a non-recursive arm at a successful branch point.
		if rand.float64() < 0.05 do thunderstorm_append_strike_branch(s, chars, canvas, column, row)
		row -= 1
		if symbol == "\\" {
			column += 1
		} else if symbol == "/" {
			column -= 1
		}
	}
	s.strike_live = true
}

thunderstorm_spawn_sparks :: proc(
	s: ^Thunderstorm_State,
	e: ^engine.Engine,
	impact: engine.Coord,
) {
	count := rand.int_range(12, 19)
	for _ in 0 ..< count {
		slot := thunderstorm_take_spark(s, e)
		offset := rand.int_range(4, 21)
		if rand.int_max(2) == 0 do offset = -offset
		target := engine.coord(impact.column + offset, e.canvas.bottom)
		control := engine.coord(
			impact.column - engine.round_half_even(f64(impact.column - target.column) / 2),
			rand.int_range(e.canvas.bottom, e.canvas.top + 1),
		)
		s.spark_starts[slot] = s.tick
		s.spark_origins[slot], s.spark_controls[slot], s.spark_targets[slot] =
			impact, control, target
		s.spark_steps[slot] = max(
			engine.round_half_even(
				engine.quadratic_bezier_length(impact, control, target) /
				rand.float64_range(0.1, 0.25),
			),
			1,
		)
		id := s.spark_ids[slot]
		e.chars.current_coord[id] = impact
		e.chars.visual[id].symbol =
			s.config.spark_symbols[rand.int_max(len(s.config.spark_symbols))]
		e.chars.visual[id].fg = s.config.spark_glow_color
		e.chars.is_visible[id] = true
		append(&s.spark_active, slot)
	}
}

thunderstorm_reveal_strike :: proc(s: ^Thunderstorm_State, e: ^engine.Engine) {
	if !s.strike_live do return
	if s.strike_pending_head < len(s.strike_pending) {
		if s.strike_delay > 0 {
			s.strike_delay -= 1
			return
		}
		count := rand.int_range(1, 4)
		for _ in 0 ..< count {
			if s.strike_pending_head == len(s.strike_pending) do break
			id := s.strike_pending[s.strike_pending_head]
			s.strike_pending_head += 1
			e.chars.is_visible[id] = true
		}
		s.strike_delay = 1
		if s.strike_pending_head != len(s.strike_pending) do return
		s.strike_flash_age = 0
		impact := e.chars.current_coord[s.strike_pending[len(s.strike_pending) - 1]]
		thunderstorm_spawn_sparks(s, e, impact)
		return
	}

	// Seven flash colors at six ticks, then six fade colors at two ticks.
	age := s.strike_flash_age
	if age < 42 {
		step := min(age / 6, 7)
		color := engine.gradient_between_step(
			s.config.lightning_color,
			engine.adjust_color_brightness(s.config.lightning_color, 1.7),
			7,
			step,
		)
		for id in s.strike_pending do e.chars.visual[id].fg = color
	} else if age < 54 {
		step := min((age - 42) / 2, 6)
		color := engine.gradient_between_step(
			s.config.lightning_color,
			e.cfg.terminal_background_color,
			6,
			step,
		)
		for id in s.strike_pending do e.chars.visual[id].fg = color
	} else {
		for id in s.strike_pending {
			e.chars.is_visible[id] = false
			p := e.chars.current_coord[id]
			if !engine.canvas_in(e.canvas, p) do continue
			input_id := s.input_at_cell[thunderstorm_cell_index(e.canvas, p)]
			if input_id >= 0 {
				slot := s.input_slot_by_id[input_id]
				if slot >= 0 {
					if s.glow_starts[slot] < 0 do append(&s.glow_active, slot)
					s.glow_starts[slot] = s.tick
				}
			}
		}
		clear(&s.strike_pending)
		s.strike_live = false
		return
	}
	s.strike_flash_age += 1
}

thunderstorm_update_rain :: proc(s: ^Thunderstorm_State, chars: ^engine.Character_Storage) {
	active := &s.rain_active
	write := 0
	for read in 0 ..< len(active^) {
		slot := active^[read]
		age := s.tick - s.rain_starts[slot]
		id := s.rain_ids[slot]
		if age >= s.rain_steps[slot] {
			chars.is_visible[id] = false
			append(&s.rain_free, slot)
			continue
		}
		chars.current_coord[id] = engine.coord_on_line(
			s.rain_origins[slot],
			s.rain_targets[slot],
			f64(age + 1) / f64(s.rain_steps[slot]),
		)
		active^[write] = slot
		write += 1
	}
	resize(active, write)
}

thunderstorm_update_sparks :: proc(
	s: ^Thunderstorm_State,
	chars: ^engine.Character_Storage,
	background: engine.Color,
) {
	active := &s.spark_active
	write := 0
	for read in 0 ..< len(active^) {
		slot := active^[read]
		age := s.tick - s.spark_starts[slot]
		id := s.spark_ids[slot]
		if age < s.spark_steps[slot] {
			chars.current_coord[id] = engine.coord_on_quadratic_bezier(
				s.spark_origins[slot],
				s.spark_controls[slot],
				s.spark_targets[slot],
				ease.ease(.Circular_Out, f64(age + 1) / f64(s.spark_steps[slot])),
			)
		} else {
			cool_step := (age - s.spark_steps[slot]) / s.config.spark_glow_time
			if cool_step > 7 {
				chars.is_visible[id] = false
				s.spark_starts[slot] = -1
				append(&s.spark_free, slot)
				continue
			}
			chars.visual[id].fg = engine.gradient_between_step(
				s.config.spark_glow_color,
				background,
				7,
				cool_step,
			)
		}
		active^[write] = slot
		write += 1
	}
	resize(active, write)
}

thunderstorm_update_text :: proc(s: ^Thunderstorm_State, chars: ^engine.Character_Storage) {
	visual_fg := chars.visual
	write := 0
	for i in s.glow_active {
		id := s.characters[i]
		start := s.glow_starts[i]
		step := (s.tick - start) / s.config.text_glow_time
		if step > 7 {
			s.glow_starts[i] = -1
			visual_fg[id].fg = s.storm_colors[i]
			visual_fg[id].bg = s.color_handling == .Dynamic ? s.storm_bg[i] : nil
			continue
		}
		visual_fg[id].fg = engine.gradient_between_step(
			s.config.glowing_text_color,
			s.storm_colors[i],
			7,
			step,
		)
		visual_fg[id].bg = s.color_handling == .Dynamic ? s.storm_bg[i] : nil
		s.glow_active[write] = i
		write += 1
	}
	resize(&s.glow_active, write)
}

thunderstorm_render_candidates :: proc(s: ^Thunderstorm_State) -> []engine.Char_Id {
	resize(&s.render_ids, len(s.characters))
	for slot in s.rain_active do append(&s.render_ids, s.rain_ids[slot])
	append(&s.render_ids, ..s.strike_pending[:])
	for slot in s.spark_active do append(&s.render_ids, s.spark_ids[slot])
	return s.render_ids[:]
}

thunderstorm_next :: proc(s: ^Thunderstorm_State, e: ^engine.Engine) -> ([]engine.Char_Id, bool) {
	chars := &e.chars
	switch s.phase {
	case .Prestorm:
		step := min(s.phase_tick / 12, 7)
		for id, i in s.characters {
			chars.visual[id].fg = engine.gradient_between_step(
				s.final_colors[i],
				s.storm_colors[i],
				7,
				step,
			)
			if s.color_handling == .Dynamic {
				if bg, ok := s.visible_bg[i].?; ok {
					chars.visual[id].bg = engine.gradient_between_step(
						bg,
						s.storm_bg[i].?,
						7,
						step,
					)
				} else {
					chars.visual[id].bg = nil
				}
			}
		}
		s.phase_tick += 1
		if s.phase_tick > 84 {
			s.phase = .Storm
			s.phase_tick = 0
			s.storm_started = time.tick_now()
		}
	case .Storm:
		thunderstorm_spawn_rain(s, chars, e.canvas)
		if !s.strike_live && rand.float64() < 0.008 do thunderstorm_begin_strike(s, chars, e.canvas)
		thunderstorm_reveal_strike(s, e)
		thunderstorm_update_rain(s, chars)
		thunderstorm_update_sparks(s, chars, e.cfg.terminal_background_color)
		thunderstorm_update_text(s, chars)
		if time.duration_seconds(time.tick_since(s.storm_started)) >= f64(s.config.storm_time) &&
		   !s.strike_live {
			for id in s.rain_ids do chars.is_visible[id] = false
			for id in s.spark_ids do chars.is_visible[id] = false
			clear(&s.rain_active)
			clear(&s.spark_active)
			s.phase = .Poststorm
			s.phase_tick = 0
		}
	case .Poststorm:
		step := min(s.phase_tick / 12, 7)
		for id, i in s.characters {
			chars.visual[id].fg = engine.gradient_between_step(
				s.storm_colors[i],
				s.final_colors[i],
				7,
				step,
			)
			if s.color_handling == .Dynamic {
				if bg, ok := s.storm_bg[i].?; ok {
					chars.visual[id].bg = engine.gradient_between_step(
						bg,
						s.visible_bg[i].?,
						7,
						step,
					)
				} else {
					chars.visual[id].bg = nil
				}
			}
		}
		s.phase_tick += 1
		if s.phase_tick > 84 {
			if s.color_handling == .Dynamic {
				for id in s.characters do engine.dynamic_apply_input_colors(&chars.visual[id], chars.input_style[id])
			}
			return nil, false
		}
	}
	s.tick += 1
	return thunderstorm_render_candidates(s), true
}
