package engine

import "core:math"

// Canvas bounds, anchoring, and the clipped terminal viewport.

Anchor :: enum {
	N,
	Ne,
	E,
	Se,
	S,
	Sw,
	W,
	Nw,
	C,
}

anchor_parse :: proc(s: string) -> (Anchor, bool) {
	switch s {
	case "n":
		return .N, true
	case "ne":
		return .Ne, true
	case "e":
		return .E, true
	case "se":
		return .Se, true
	case "s":
		return .S, true
	case "sw":
		return .Sw, true
	case "w":
		return .W, true
	case "nw":
		return .Nw, true
	case "c":
		return .C, true
	}
	return .Sw, false
}

Canvas :: struct {
	top, right, bottom, left:  int,
	center_row, center_column: int,
	center:                    Coord,
	width, height:             int,
	text_left, text_right:     int,
	text_top, text_bottom:     int,
	text_width, text_height:   int,
	text_center_row:           int,
	text_center_column:        int,
	text_center:               Coord,
}

canvas_make :: proc(top, right: int) -> Canvas {
	c: Canvas
	c.top, c.right, c.bottom, c.left = top, right, 1, 1
	c.center_row = max(math.floor_div(top, 2), c.bottom)
	if top % 2 != 0 && top > 1 do c.center_row += 1
	c.center_column = max(math.floor_div(right, 2), c.left)
	if right % 2 != 0 && right > 1 do c.center_column += 1
	c.center = coord(c.center_column, c.center_row)
	c.width, c.height = right, top
	return c
}

canvas_in :: proc(c: Canvas, p: Coord) -> bool {
	return c.left <= p.column && p.column <= c.right && c.bottom <= p.row && p.row <= c.top
}

canvas_in_text :: proc(c: Canvas, p: Coord) -> bool {
	return(
		c.text_left <= p.column &&
		p.column <= c.text_right &&
		c.text_bottom <= p.row &&
		p.row <= c.text_top \
	)
}

canvas_random_column :: proc(canvas: Canvas, within_text: bool) -> int {
	lo, hi := canvas.left, canvas.right
	if within_text do lo, hi = canvas.text_left, canvas.text_right
	return random_range(lo, hi + 1)
}

canvas_random_row :: proc(canvas: Canvas, within_text: bool) -> int {
	lo, hi := canvas.bottom, canvas.top
	if within_text do lo, hi = canvas.text_bottom, canvas.text_top
	return random_range(lo, hi + 1)
}

canvas_random_coord :: proc(canvas: Canvas, outside_scope, within_text: bool) -> Coord {
	if outside_scope {
		above := coord(canvas_random_column(canvas, false), canvas.top + 1)
		below := coord(canvas_random_column(canvas, false), canvas.bottom - 1)
		left := coord(canvas.left - 1, canvas_random_row(canvas, false))
		right := coord(canvas.right + 1, canvas_random_row(canvas, false))
		return ([4]Coord{above, below, left, right})[random_below(4)]
	}
	return coord(canvas_random_column(canvas, within_text), canvas_random_row(canvas, within_text))
}

Render_Layout :: struct {
	visible_top, visible_bottom: int,
	visible_right, visible_left: int,
	col_offset, row_offset:      int,
}

wrapped_line_count :: proc(line_widths: []int, width: int) -> int {
	count := 0
	for line_width in line_widths {
		remaining := line_width
		for remaining > width {
			count += 1
			remaining -= width
		}
		count += 1
	}
	return count
}

canvas_dimensions :: proc(
	cfg: Terminal_Config,
	line_widths: []int,
	term_w, term_h: int,
) -> (
	int,
	int,
) {
	input_width := 0
	for width in line_widths do input_width = max(input_width, width)
	input_height := len(line_widths)
	width: int
	if cfg.canvas_width > 0 {
		width = cfg.canvas_width
	} else if cfg.canvas_width == 0 {
		width = term_w
	} else {
		width = cfg.ignore_terminal_dimensions ? input_width : min(term_w, input_width)
	}
	height: int
	if cfg.canvas_height > 0 {
		height = cfg.canvas_height
	} else if cfg.canvas_height == 0 {
		height = term_h
	} else if cfg.ignore_terminal_dimensions {
		height = input_height
	} else if cfg.wrap_text {
		height = min(wrapped_line_count(line_widths, width), term_h)
	} else {
		height = min(term_h, input_height)
	}
	return height, width
}

// Construction and resize admission use the same dimensions, offsets and clip.
layout_make :: proc(
	cfg: Terminal_Config,
	line_widths: []int,
	term_w, term_h: int,
) -> (
	Canvas,
	Render_Layout,
) {
	canvas_h, canvas_w := canvas_dimensions(cfg, line_widths, term_w, term_h)
	canvas := canvas_make(canvas_h, canvas_w)
	layout: Render_Layout
	layout_term_w, layout_term_h := term_w, term_h
	if cfg.ignore_terminal_dimensions {
		layout_term_w, layout_term_h = canvas.right, canvas.top
	} else {
		layout.col_offset, layout.row_offset = canvas_offsets(cfg, canvas, term_w, term_h)
	}
	layout.visible_top = min(canvas.top + layout.row_offset, layout_term_h)
	layout.visible_bottom = max(canvas.bottom + layout.row_offset, 1)
	layout.visible_right = min(canvas.right + layout.col_offset, layout_term_w)
	layout.visible_left = max(canvas.left + layout.col_offset, 1)
	return canvas, layout
}

canvas_offsets :: proc(cfg: Terminal_Config, canvas: Canvas, term_w, term_h: int) -> (int, int) {
	col, row := 0, 0
	switch cfg.anchor_canvas {
	case .S, .N, .C:
		col = math.floor_div(term_w, 2) - math.floor_div(canvas.width, 2)
	case .Se, .E, .Ne:
		col = term_w - canvas.width
	case .Sw, .W, .Nw:
		col = 0
	}
	switch cfg.anchor_canvas {
	case .W, .E, .C:
		row = math.floor_div(term_h, 2) - math.floor_div(canvas.height, 2)
	case .Nw, .N, .Ne:
		row = term_h - canvas.height
	case .Sw, .S, .Se:
		row = 0
	}
	return col, row
}

anchor_text :: proc(e: ^Engine, characters: []Particle_Id, anchor: Anchor) {
	if len(characters) == 0 do return
	input_width, input_height := 0, 0
	for id in characters {
		p := e.particles.initial_coord[id]
		input_width = max(input_width, p.column)
		input_height = max(input_height, p.row)
	}
	col_delta, row_delta := 0, 0
	if input_width != e.canvas.width {
		switch anchor {
		case .S, .N, .C:
			col_delta = e.canvas.center_column - math.floor_div(input_width, 2)
		case .Se, .E, .Ne:
			col_delta = e.canvas.right - input_width
		case .Sw, .W, .Nw:
			col_delta = e.canvas.left - 1
		}
	}
	if input_height != e.canvas.height {
		switch anchor {
		case .W, .E, .C:
			row_delta = math.floor_div(e.canvas.height - input_height, 2)
		case .Nw, .N, .Ne:
			row_delta = e.canvas.top - input_height
		case .Sw, .S, .Se:
			row_delta = e.canvas.bottom - 1
		}
	}
	for id in characters {
		p := e.particles.initial_coord[id]
		p.column += col_delta
		p.row += row_delta
		e.particles.initial_coord[id] = p
		e.particles.current_coord[id] = p
	}
	first := true
	for id in characters {
		p := e.particles.initial_coord[id]
		if !canvas_in(e.canvas, p) do continue
		if first {
			e.canvas.text_left, e.canvas.text_right = p.column, p.column
			e.canvas.text_top, e.canvas.text_bottom = p.row, p.row
			first = false
		} else {
			e.canvas.text_left = min(e.canvas.text_left, p.column)
			e.canvas.text_right = max(e.canvas.text_right, p.column)
			e.canvas.text_top = max(e.canvas.text_top, p.row)
			e.canvas.text_bottom = min(e.canvas.text_bottom, p.row)
		}
	}
	e.canvas.text_width = max(e.canvas.text_right - e.canvas.text_left + 1, 1)
	e.canvas.text_height = max(e.canvas.text_top - e.canvas.text_bottom + 1, 1)
	e.canvas.text_center_row =
		e.canvas.text_bottom + math.floor_div(e.canvas.text_top - e.canvas.text_bottom, 2)
	e.canvas.text_center_column =
		e.canvas.text_left + math.floor_div(e.canvas.text_right - e.canvas.text_left, 2)
	e.canvas.text_center = coord(e.canvas.text_center_column, e.canvas.text_center_row)
}
