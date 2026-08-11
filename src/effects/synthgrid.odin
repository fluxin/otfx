package effects

import "../engine"

import "core:fmt"
import "core:math"
import "core:math/rand"

Synthgrid_Config :: struct {
	grid_gradient_stops:     [dynamic]engine.Color,
	grid_gradient_steps:     [dynamic]int,
	grid_gradient_direction: engine.Gradient_Direction,
	text_gradient_stops:     [dynamic]engine.Color,
	text_gradient_steps:     [dynamic]int,
	text_gradient_direction: engine.Gradient_Direction,
	grid_row_symbol:         string,
	grid_column_symbol:      string,
	text_generation_symbols: [dynamic]string,
	max_active_blocks:       f64,
}

synthgrid_config_default :: proc() -> Synthgrid_Config {
	cfg := Synthgrid_Config {
		grid_gradient_direction = .Diagonal,
		text_gradient_direction = .Vertical,
		grid_row_symbol         = "─",
		grid_column_symbol      = "│",
		max_active_blocks       = 0.1,
	}
	append(
		&cfg.grid_gradient_stops,
		engine.Color{0xCC, 0x00, 0xCC},
		engine.Color{0xFF, 0xFF, 0xFF},
	)
	append(&cfg.grid_gradient_steps, 12)
	append(
		&cfg.text_gradient_stops,
		..[]engine.Color {
			engine.Color{0x8A, 0x00, 0x8A},
			engine.Color{0x00, 0xD1, 0xFF},
			engine.Color{0xFF, 0xFF, 0xFF},
		},
	)
	append(&cfg.text_gradient_steps, 12)
	append(&cfg.text_generation_symbols, ..[]string{"░", "▒", "▓"})
	return cfg
}

synthgrid_parse :: proc(cfg: ^Synthgrid_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--grid-gradient-stops":
			if !parse_colors_flag(&cfg.grid_gradient_stops, args, &i, value, has_value) do return false
		case "--grid-gradient-steps":
			if !parse_ints_flag(&cfg.grid_gradient_steps, args, &i, value, has_value) do return false
		case "--grid-gradient-direction":
			if !parse_gdir_flag(&cfg.grid_gradient_direction, args, &i, value, has_value) do return false
		case "--text-gradient-stops":
			if !parse_colors_flag(&cfg.text_gradient_stops, args, &i, value, has_value) do return false
		case "--text-gradient-steps":
			if !parse_ints_flag(&cfg.text_gradient_steps, args, &i, value, has_value) do return false
		case "--text-gradient-direction":
			if !parse_gdir_flag(&cfg.text_gradient_direction, args, &i, value, has_value) do return false
		case "--grid-row-symbol":
			if !parse_symbol_flag(&cfg.grid_row_symbol, args, &i, value, has_value) do return false
		case "--grid-column-symbol":
			if !parse_symbol_flag(&cfg.grid_column_symbol, args, &i, value, has_value) do return false
		case "--text-generation-symbols":
			if !parse_symbols_flag(&cfg.text_generation_symbols, args, &i, value, has_value) do return false
		case "--max-active-blocks":
			if !parse_float_flag(&cfg.max_active_blocks, args, &i, value, has_value) || cfg.max_active_blocks <= 0 || cfg.max_active_blocks > 1 do return false
		case:
			fmt.eprintln("Error: unknown synthgrid option: ", name)
			return false
		}
	}
	return true
}

Synthgrid_Phase :: enum {
	Grid_Expand,
	Text,
	Grid_Collapse,
}

SYNTHGRID_MAX_GENERATION_FRAMES :: 30

Synthgrid_State :: struct {
	config:                  Synthgrid_Config,
	grid_ids:                [dynamic]engine.Char_Id,
	grid_offsets:            [dynamic]int,
	grid_extended:           [dynamic]int,
	grid_is_horizontal:      [dynamic]bool,
	cells:                   [dynamic]engine.Char_Id,
	groups:                  engine.Char_Groups,
	final_colors:            [dynamic]engine.Color, // Char_Id indexed
	start_ticks:             [dynamic]int, // Char_Id indexed
	group_by_id:             [dynamic]int, // Char_Id indexed
	generation_slot_by_id:   [dynamic]int, // Char_Id indexed
	group_remaining:         [dynamic]int,
	group_order:             [dynamic]int,
	generation_frame_counts: [dynamic]u8, // dense canvas-cell slot indexed
	generation_symbols:      [dynamic]string, // cell slot × fixed frame width
	generation_colors:       [dynamic]engine.Color,
	next_group:              int,
	active_count:            int,
	active_limit:            int,
	tick:                    int,
	phase:                   Synthgrid_Phase,
	color_handling:          engine.Existing_Color_Handling,
}

// Same build-time gap selection as TerminalTextEffects. The resulting grid is
// deliberately sparse: it defines generation blocks rather than wallpaper.
synthgrid_find_even_gap :: proc(dimension: int) -> int {
	d := dimension - 2
	if d <= 0 do return 0
	target := math.floor_div(d, 5)
	best := 4
	best_delta := target - best
	if best_delta < 0 do best_delta = -best_delta
	found := false
	for gap := d; gap > 4; gap -= 1 {
		remainder := d - math.floor_div(d, gap) * gap
		if remainder > 1 do continue
		delta := target - gap
		if delta < 0 do delta = -delta
		if !found || delta < best_delta {
			best, best_delta, found = gap, delta, true
		}
	}
	return found ? best : 4
}

// Lines are one flat character pool plus offsets. Each line owns only an
// extended count, so expanding/collapsing has no object graph or allocations.
synthgrid_add_grid_line :: proc(
	s: ^Synthgrid_State,
	e: ^engine.Engine,
	origin: engine.Coord,
	horizontal: bool,
	sampler: engine.Gradient_Sampler,
	spectrum: []engine.Color,
) {
	symbol := horizontal ? s.config.grid_row_symbol : s.config.grid_column_symbol
	if horizontal {
		for column in e.canvas.left ..= e.canvas.right {
			position := engine.coord(column, origin.row)
			id := engine.add_character(e, symbol, position)
			e.chars.layer[id] = 2
			e.chars.is_visible[id] = false
			e.chars.visual[id].fg = engine.gradient_sample(sampler, spectrum, position)
			append(&s.grid_ids, id)
		}
	} else {
		// Horizontal border lines own the top/bottom intersections, exactly as
		// the reference does, so vertical lines stop one row short of the top.
		for row in e.canvas.bottom ..< e.canvas.top {
			position := engine.coord(origin.column, row)
			id := engine.add_character(e, symbol, position)
			e.chars.layer[id] = 2
			e.chars.is_visible[id] = false
			e.chars.visual[id].fg = engine.gradient_sample(sampler, spectrum, position)
			append(&s.grid_ids, id)
		}
	}
	append(&s.grid_offsets, len(s.grid_ids))
	append(&s.grid_extended, 0)
	append(&s.grid_is_horizontal, horizontal)
}

synthgrid_build :: proc(s: ^Synthgrid_State, e: ^engine.Engine) {
	grid_spectrum := engine.gradient_make(
		s.config.grid_gradient_stops[:],
		s.config.grid_gradient_steps[:],
		false,
	)
	defer delete(grid_spectrum[:])
	grid_sampler := engine.gradient_sampler(
		e.canvas.bottom,
		e.canvas.top,
		e.canvas.left,
		e.canvas.right,
		s.config.grid_gradient_direction,
	)
	text_spectrum := engine.gradient_make(
		s.config.text_gradient_stops[:],
		s.config.text_gradient_steps[:],
		false,
	)
	defer delete(text_spectrum[:])
	text_sampler := engine.gradient_sampler(
		e.canvas.text_bottom,
		e.canvas.text_top,
		e.canvas.text_left,
		e.canvas.text_right,
		s.config.text_gradient_direction,
	)

	input_coords := e.chars.input_coord
	visible := e.chars.is_visible

	append(&s.grid_offsets, 0)
	left, right := e.canvas.left, e.canvas.right
	bottom, top := e.canvas.bottom, e.canvas.top
	synthgrid_add_grid_line(s, e, engine.coord(left, bottom), true, grid_sampler, grid_spectrum[:])
	synthgrid_add_grid_line(s, e, engine.coord(left, top), true, grid_sampler, grid_spectrum[:])
	synthgrid_add_grid_line(
		s,
		e,
		engine.coord(left, bottom),
		false,
		grid_sampler,
		grid_spectrum[:],
	)
	synthgrid_add_grid_line(
		s,
		e,
		engine.coord(right, bottom),
		false,
		grid_sampler,
		grid_spectrum[:],
	)

	row_gap, column_gap: int
	if top > 2 * right {
		row_gap = synthgrid_find_even_gap(top) + 1
		column_gap = row_gap * 2
	} else {
		column_gap = synthgrid_find_even_gap(right) + 1
		row_gap = math.floor_div(column_gap, 2)
	}
	row_ends: [dynamic]int
	column_ends: [dynamic]int
	defer delete(row_ends[:])
	defer delete(column_ends[:])
	for row := bottom + max(row_gap, 1); row < top; row += max(row_gap, 1) {
		if top - row < 2 do continue
		synthgrid_add_grid_line(
			s,
			e,
			engine.coord(left, row),
			true,
			grid_sampler,
			grid_spectrum[:],
		)
		append(&row_ends, row)
	}
	for column := left + max(column_gap, 1); column < right; column += max(column_gap, 1) {
		if right - column < 2 do continue
		synthgrid_add_grid_line(
			s,
			e,
			engine.coord(column, bottom),
			false,
			grid_sampler,
			grid_spectrum[:],
		)
		append(&column_ends, column)
	}
	append(&row_ends, top + 1)
	append(&column_ends, right + 1)

	// add_character may grow the engine SoA, so refresh these direct columns
	// before using them for block and text setup.
	input_coords = e.chars.input_coord
	visible = e.chars.is_visible

	// Rust's coordinate table maps every canvas cell to either input text or a
	// fill character. Keep the same dense direct lookup: block static fills are
	// real characters, not a texture synthesized only where text exists.
	base_query := engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas}
	s.cells = engine.get_characters(
		base_query,
		engine.CHAR_FILTER_ALL_FILLS,
		.Top_Bottom_Left_Right,
	)
	cell_ids := make([dynamic]engine.Char_Id, e.canvas.width * e.canvas.height)
	defer delete(cell_ids[:])
	for id in s.cells {
		p := input_coords[id]
		cell_ids[(p.row - bottom) * e.canvas.width + (p.column - left)] = id
	}

	// Blocks follow the grid boundaries, not radial distance. Preserve them as
	// contiguous character slices and shuffle only the small group-order column.
	previous_row := bottom
	for row_end in row_ends {
		previous_column := left
		for column_end in column_ends {
			start := len(s.groups.members)
			for row in previous_row ..< row_end {
				for column in previous_column ..< column_end {
					append(
						&s.groups.members,
						cell_ids[(row - bottom) * e.canvas.width + (column - left)],
					)
				}
			}
			append(&s.groups.spans, engine.Span{start, len(s.groups.members) - start})
			previous_column = column_end
		}
		previous_row = row_end
	}

	s.final_colors = make([dynamic]engine.Color, len(e.chars))
	s.color_handling = e.cfg.existing_color_handling
	s.start_ticks = make([dynamic]int, len(e.chars))
	s.group_by_id = make([dynamic]int, len(e.chars))
	s.generation_slot_by_id = make([dynamic]int, len(e.chars))
	for i in 0 ..< len(s.start_ticks) do s.start_ticks[i], s.group_by_id[i], s.generation_slot_by_id[i] = -1, -1, -1
	cell_count := len(s.cells)
	s.generation_frame_counts = make([dynamic]u8, cell_count)
	s.generation_symbols = make([dynamic]string, cell_count * SYNTHGRID_MAX_GENERATION_FRAMES)
	s.generation_colors = make([dynamic]engine.Color, cell_count * SYNTHGRID_MAX_GENERATION_FRAMES)
	is_fill := e.chars.is_fill
	for id, slot in s.cells {
		if !is_fill[id] do s.final_colors[id] = engine.gradient_sample(text_sampler, text_spectrum[:], input_coords[id])
		visible[id] = false
		s.generation_slot_by_id[id] = slot
		frame_count := rand.int_range(15, SYNTHGRID_MAX_GENERATION_FRAMES + 1)
		s.generation_frame_counts[slot] = u8(frame_count)
		base := slot * SYNTHGRID_MAX_GENERATION_FRAMES
		for frame in 0 ..< frame_count {
			s.generation_symbols[base + frame] =
				s.config.text_generation_symbols[rand.int_max(len(s.config.text_generation_symbols))]
			s.generation_colors[base + frame] = text_spectrum[rand.int_max(len(text_spectrum))]
		}
	}
	group_count := len(s.groups.spans)
	s.group_remaining = make([dynamic]int, group_count)
	s.group_order = make([dynamic]int, group_count)
	for group in 0 ..< group_count {
		s.group_order[group] = group
		for id in engine.group_members(s.groups, group) do s.group_by_id[id] = group
	}
	rand.shuffle(s.group_order[:])

	s.active_limit = max(int(f64(group_count) * s.config.max_active_blocks), 1)
}

synthgrid_next :: proc(s: ^Synthgrid_State, e: ^engine.Engine) -> ([]engine.Char_Id, bool) {
	visible := e.chars.is_visible
	visual_symbols := e.chars.visual
	visual_fg := e.chars.visual
	input_symbols := e.chars.input_symbol
	if s.phase == .Grid_Expand {
		all_extended := true
		for line in 0 ..< len(s.grid_extended) {
			start, end := s.grid_offsets[line], s.grid_offsets[line + 1]
			extended := s.grid_extended[line]
			if extended == end - start do continue
			all_extended = false
			count := s.grid_is_horizontal[line] ? 3 : 1
			stop := min(extended + count, end - start)
			for i in extended ..< stop do visible[s.grid_ids[start + i]] = true
			s.grid_extended[line] = stop
		}
		if all_extended {
			s.phase = .Text
		}
		return nil, true
	}

	if s.phase == .Text {
		for s.next_group < len(s.groups.spans) && s.active_count < s.active_limit {
			group := s.group_order[s.next_group]
			members := engine.group_members(s.groups, group)
			s.group_remaining[group] = len(members)
			for id in members {
				s.start_ticks[id] = s.tick
				visible[id] = true
			}
			s.active_count += 1
			s.next_group += 1
		}
		is_fill := e.chars.is_fill
		for id in s.cells {
			start := s.start_ticks[id]
			if start < 0 do continue
			age := s.tick - start
			slot := s.generation_slot_by_id[id]
			frame_count := int(s.generation_frame_counts[slot])
			frame := age / 2
			if frame < frame_count {
				index := slot * SYNTHGRID_MAX_GENERATION_FRAMES + frame
				visual_symbols[id].symbol = s.generation_symbols[index]
				visual_fg[id].fg = s.generation_colors[index]
			} else {
				visual_symbols[id].symbol = input_symbols[id]
				if s.color_handling == .Dynamic {
					engine.dynamic_apply_input_colors(&visual_fg[id], e.chars.input_style[id])
				} else {
					visual_fg[id].fg = is_fill[id] ? nil : s.final_colors[id]
				}
				if age == frame_count * 2 {
					s.start_ticks[id] = -2
					group := s.group_by_id[id]
					s.group_remaining[group] -= 1
					if s.group_remaining[group] == 0 do s.active_count -= 1
				}
			}
		}
		s.tick += 1
		if s.next_group == len(s.groups.spans) && s.active_count == 0 {
			s.phase = .Grid_Collapse
		}
		return nil, true
	}

	all_collapsed := true
	for line in 0 ..< len(s.grid_extended) {
		start := s.grid_offsets[line]
		extended := s.grid_extended[line]
		if extended == 0 do continue
		all_collapsed = false
		count := s.grid_is_horizontal[line] ? 3 : 1
		stop := max(extended - count, 0)
		for i := extended; i > stop; {
			i -= 1
			visible[s.grid_ids[start + i]] = false
		}
		s.grid_extended[line] = stop
	}
	if all_collapsed do return nil, false
	return nil, true
}
