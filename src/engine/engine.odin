package engine

import "base:intrinsics"
import "core:c/libc"
import "core:fmt"
import "core:math"
import ease "core:math/ease"
import rand "core:math/rand"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:time"
import "core:unicode/utf8"

// ---------------------------------------------------------------------------
// config / canvas
// ---------------------------------------------------------------------------

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

Terminal_Config :: struct {
	tab_width:                  int,
	no_color:                   bool,
	wrap_text:                  bool,
	frame_rate:                 int,
	max_frames:                 Maybe(int),
	canvas_width:               int,
	canvas_height:              int,
	anchor_canvas:              Anchor,
	anchor_text:                Anchor,
	ignore_terminal_dimensions: bool,
	reuse_canvas:               bool,
	no_eol:                     bool,
	no_restore_cursor:          bool,
	terminal_background_color:  Color,
}

// SIGWINCH only records a signal-safe flag. The interactive run loop consumes
// it after a short quiet period, checks whether layout actually changes, then
// returns to main so a fresh engine/effect can be built against new geometry.
resize_signal_pending: libc.sig_atomic_t

resize_signal_handler :: proc "c" (_: i32) {
	intrinsics.atomic_store(&resize_signal_pending, libc.sig_atomic_t(1))
}

install_resize_handler :: proc() {
	_ = libc.signal(28, resize_signal_handler) // SIGWINCH on supported Linux targets
}

take_resize_signal :: proc() -> bool {
	return intrinsics.atomic_exchange(&resize_signal_pending, libc.sig_atomic_t(0)) != 0
}

config_default :: proc() -> Terminal_Config {
	return {
		tab_width = 4,
		frame_rate = 60,
		canvas_width = -1,
		canvas_height = -1,
		anchor_canvas = .Sw,
		anchor_text = .Sw,
		terminal_background_color = {0, 0, 0},
	}
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
	return rand.int_range(lo, hi + 1)
}

canvas_random_row :: proc(canvas: Canvas, within_text: bool) -> int {
	lo, hi := canvas.bottom, canvas.top
	if within_text do lo, hi = canvas.text_bottom, canvas.text_top
	return rand.int_range(lo, hi + 1)
}

canvas_random_coord :: proc(canvas: Canvas, outside_scope, within_text: bool) -> Coord {
	if outside_scope {
		above := coord(canvas_random_column(canvas, false), canvas.top + 1)
		below := coord(canvas_random_column(canvas, false), canvas.bottom - 1)
		left := coord(canvas.left - 1, canvas_random_row(canvas, false))
		right := coord(canvas.right + 1, canvas_random_row(canvas, false))
		return ([4]Coord{above, below, left, right})[rand.int_max(4)]
	}
	return coord(canvas_random_column(canvas, within_text), canvas_random_row(canvas, within_text))
}

// ---------------------------------------------------------------------------
// animation / motion data — flat pools, integer handles, no callbacks
// ---------------------------------------------------------------------------

Color_Pair :: struct {
	fg: Maybe(Color),
	bg: Maybe(Color),
}

Visual :: struct {
	symbol: string,
	fg, bg: Maybe(Color),
	bold:   bool,
}

Frame :: struct {
	visual:   Visual,
	duration: int,
}

Scene :: struct {
	frames:      #soa[dynamic]Frame,
	frame_index: int,
	frame_tick:  int,
}

scene_complete :: proc(s: Scene) -> bool {
	return s.frame_index >= len(s.frames)
}

scene_add_frame :: proc(
	s: ^Scene,
	symbol: string,
	duration: int,
	fg, bg: Maybe(Color),
	bold: bool,
) {
	assert(duration >= 1)
	append(&s.frames, Frame{Visual{symbol, fg, bg, bold}, duration})
}

// Upstream apply_gradient_to_symbols over a fg/bg spectrum pair.
scene_add_gradient :: proc(
	s: ^Scene,
	symbols: []string,
	duration: int,
	fg_spectrum, bg_spectrum: []Color,
) {
	pairs := gradient_pairs(fg_spectrum, bg_spectrum)
	defer delete(pairs[:])
	assert(len(symbols) > 0)
	assert(len(pairs) > 0)
	// Match Animation.apply_gradient_to_symbols: distribute the shorter input
	// in contiguous runs across the longer one. Round-robin symbol selection
	// turns a beam's fat-to-thin profile into scattered glyphs.
	repeat_factor: int
	overflow_count: int
	overflow_used := false
	small_index := 0
	current_repeat := 0
	if len(symbols) >= len(pairs) {
		repeat_factor = len(symbols) / len(pairs)
		overflow_count = len(symbols) % len(pairs)
		for sym in symbols {
			if current_repeat >= repeat_factor {
				if overflow_count > 0 {
					if overflow_used {
						small_index += 1
						current_repeat = 0
						overflow_used = false
					} else {
						overflow_used = true
						overflow_count -= 1
					}
				} else {
					small_index += 1
					current_repeat = 0
				}
			}
			current_repeat += 1
			p := pairs[small_index]
			scene_add_frame(s, sym, duration, p.fg, p.bg, false)
		}
	} else {
		repeat_factor = len(pairs) / len(symbols)
		overflow_count = len(pairs) % len(symbols)
		for i in 0 ..< len(pairs) {
			if current_repeat >= repeat_factor {
				if overflow_count > 0 {
					if overflow_used {
						small_index += 1
						current_repeat = 0
						overflow_used = false
					} else {
						overflow_used = true
						overflow_count -= 1
					}
				} else {
					small_index += 1
					current_repeat = 0
				}
			}
			current_repeat += 1
			p := pairs[i]
			scene_add_frame(s, symbols[small_index], duration, p.fg, p.bg, false)
		}
	}
}

// Cyclic distribution of the larger spectrum over the smaller, upstream style.
gradient_pairs :: proc(fg, bg: []Color) -> [dynamic]Color_Pair {
	pairs: [dynamic]Color_Pair
	cyclic :: proc(pairs: ^[dynamic]Color_Pair, larger, smaller: []Color, larger_is_fg: bool) {
		repeat_factor := len(larger) / len(smaller)
		overflow_count := len(larger) % len(smaller)
		overflow_used := false
		small_index := 0
		current_repeat := 0
		for element in larger {
			if current_repeat >= repeat_factor {
				if overflow_count > 0 {
					if overflow_used {
						small_index += 1
						current_repeat = 0
						overflow_used = false
					} else {
						overflow_used = true
						overflow_count -= 1
					}
				} else {
					small_index += 1
					current_repeat = 0
				}
			}
			current_repeat += 1
			other := smaller[small_index]
			p := larger_is_fg ? Color_Pair{element, other} : Color_Pair{other, element}
			append(pairs, p)
		}
	}
	switch {
	case len(fg) > 0 && len(bg) > 0:
		if len(fg) >= len(bg) {
			cyclic(&pairs, fg, bg, true)
		} else {
			cyclic(&pairs, bg, fg, false)
		}
	case len(fg) > 0:
		for c in fg do append(&pairs, Color_Pair{c, nil})
	case:
		for c in bg do append(&pairs, Color_Pair{nil, c})
	}
	return pairs
}

scene_reset :: proc(s: ^Scene) {
	s.frame_index, s.frame_tick = 0, 0
}

// First visual of the remaining queue (resume semantics).
scene_first_visual :: proc(s: Scene) -> Visual {
	assert(len(s.frames) > 0)
	return s.frames[s.frame_index].visual
}

scene_next_visual :: proc(s: ^Scene) -> Visual {
	i := s.frame_index
	v := s.frames[i].visual
	s.frame_tick += 1
	if s.frame_tick == s.frames.duration[i] {
		s.frame_tick = 0
		s.frame_index += 1
	}
	return v
}

scene_reset_if_complete :: proc(s: ^Scene) -> bool {
	if !scene_complete(s^) do return false
	scene_reset(s)
	return true
}

step_animation :: proc(s: ^Scene) -> (Visual, bool) {
	assert(len(s.frames) > 0, "step_animation: empty scene")
	visual := scene_next_visual(s)
	return visual, scene_reset_if_complete(s)
}

Character :: struct {
	character_id:    int,
	input_symbol:    string,
	input_coord:     Coord,
	is_visible:      bool,
	is_fill:         bool,
	layer:           int,
	current_coord:   Coord,
	visual:          Visual,
	// Allocation-free derived render column. Logical appearance remains in the
	// visual above; cached records which visual render_code was built from.
	render_code:     [64]byte,
	render_code_len: u8,
	cached:          Visual,
}

Character_Storage :: #soa[dynamic]Character

character_set_visual :: proc(chars: ^Character_Storage, id: Char_Id, visual: Visual) {
	chars.visual[id] = visual
}

// ---------------------------------------------------------------------------
// engine world
// ---------------------------------------------------------------------------

Char_Id :: distinct int

Character_Kind :: enum {
	Input,
	Inner_Fill,
	Outer_Fill,
	Added,
}

Character_Filter :: bit_set[Character_Kind;u8]

CHAR_FILTER_INPUT :: Character_Filter{.Input}
CHAR_FILTER_ALL_FILLS :: Character_Filter{.Input, .Inner_Fill, .Outer_Fill}

Character_Sort :: enum {
	Top_Bottom_Left_Right,
	Random,
}

Character_Group :: enum {
	Column_L2R,
	Column_R2L,
	Row_T2B,
	Row_B2T,
	Diagonal_TL2BR,
	Diagonal_BL2TR,
	Diagonal_TR2BL,
	Diagonal_BR2TL,
	Center_Outside,
	Outside_Center,
}

group_parse :: proc(s: string) -> (Character_Group, bool) {
	switch s {
	case "column_left_to_right":
		return .Column_L2R, true
	case "column_right_to_left":
		return .Column_R2L, true
	case "row_top_to_bottom":
		return .Row_T2B, true
	case "row_bottom_to_top":
		return .Row_B2T, true
	case "diagonal_top_left_to_bottom_right":
		return .Diagonal_TL2BR, true
	case "diagonal_bottom_left_to_top_right":
		return .Diagonal_BL2TR, true
	case "diagonal_top_right_to_bottom_left":
		return .Diagonal_TR2BL, true
	case "diagonal_bottom_right_to_top_left":
		return .Diagonal_BR2TL, true
	case "center_to_outside":
		return .Center_Outside, true
	case "outside_to_center":
		return .Outside_Center, true
	}
	return .Column_L2R, false
}

Engine :: struct {
	cfg:               Terminal_Config,
	canvas:            Canvas,
	terminal_width:    int,
	terminal_height:   int,
	input_line_widths: [dynamic]int,
	resize_seen_at:    Maybe(time.Tick),
	chars:             Character_Storage, // struct-of-arrays arena
	wall_start:        f64,
	mono_start:        time.Tick,
	character_sets:    Character_Sets,
	next_character_id: int,
	visible_top:       int,
	visible_bottom:    int,
	visible_right:     int,
	visible_left:      int,
	col_offset:        int,
	row_offset:        int,
	move_to_top:       string,
	raster_storage:    [dynamic]i32, // current + previous raster in one allocation
	render_cells:      []i32,
	previous_cells:    []i32,
	out_buf:           [dynamic]byte,
	last_print:        time.Tick,
	frame_rate:        int,
}

now_wall :: proc(wall_start: f64, mono_start: time.Tick) -> f64 {
	return wall_start + time.duration_seconds(time.tick_since(mono_start))
}

get_env_str :: proc(key: string) -> string {
	buf: [256]u8
	s := os.get_env_buf(buf[:], key)
	// get_env_buf returns a slice into buf; copy off the stack
	out := make([]byte, len(s))
	copy(out, s)
	return string(out)
}

terminal_dimensions :: proc() -> (int, int) {
	cols := get_env_str("COLUMNS")
	lines := get_env_str("LINES")
	c, cok := strconv.parse_int(cols)
	l, lok := strconv.parse_int(lines)
	if cok && lok do return int(c), int(l)
	w, h := ioctl_winsize(1) // stdout
	if cok do w = int(c)
	if lok do h = int(l)
	if w <= 0 do w = 80
	if h <= 0 do h = 24
	return w, h
}

engine_make :: proc(
	input: string,
	cfg: Terminal_Config,
	formatted_allocator: mem.Allocator,
) -> Engine {
	e: Engine
	e.cfg = cfg
	e.frame_rate = cfg.frame_rate
	e.wall_start = unix_seconds(time.now())
	e.mono_start = time.tick_now()
	e.last_print = time.tick_now()

	text := input == "" ? "No Input." : input
	lines := preprocess_input(text, cfg.tab_width)

	term_w, term_h := terminal_dimensions()
	e.terminal_width, e.terminal_height = term_w, term_h
	canvas_h, canvas_w := canvas_dimensions(cfg, lines, term_w, term_h)
	e.canvas = canvas_make(canvas_h, canvas_w)

	if !cfg.ignore_terminal_dimensions {
		e.col_offset, e.row_offset = canvas_offsets(cfg, e.canvas, term_w, term_h)
	} else {
		term_w, term_h = e.canvas.right, e.canvas.top
	}
	e.visible_top = min(e.canvas.top + e.row_offset, term_h)
	e.visible_bottom = max(e.canvas.bottom + e.row_offset, 1)
	e.visible_right = min(e.canvas.right + e.col_offset, term_w)
	e.visible_left = max(e.canvas.left + e.col_offset, 1)
	e.move_to_top = fmt.aprintf(
		"%s%s%s",
		ANSI_RESTORE_CURSOR,
		ANSI_SAVE_CURSOR,
		move_cursor_up(max(e.visible_top, 0)),
		allocator = formatted_allocator,
	)

	setup_input_characters(&e, lines)
	e.input_line_widths = make([dynamic]int, len(lines))
	for line, i in lines do e.input_line_widths[i] = line.width
	// drop characters that landed outside the canvas (same as upstream)
	write := 0
	for id in e.character_sets.input {
		p := e.chars.input_coord[id]
		if p.row <= e.canvas.top && p.column <= e.canvas.right {
			e.character_sets.input[write] = id
			write += 1
		}
	}
	resize(&e.character_sets.input, write)
	raster_cells := max(
		e.canvas.top * e.canvas.right,
		max(e.visible_top, 0) * max(e.visible_right, 0),
	)
	e.raster_storage = make([dynamic]i32, raster_cells * 2)
	e.render_cells = e.raster_storage[:raster_cells]
	e.previous_cells = e.raster_storage[raster_cells:]
	for i in 0 ..< raster_cells {
		e.render_cells[i] = EMPTY_CELL
		e.previous_cells[i] = EMPTY_CELL
	}
	for id in e.character_sets.input {
		c := e.chars.input_coord[id]
		e.render_cells[(c.row - 1) * e.canvas.right + (c.column - 1)] = i32(id)
	}
	make_fill_characters(&e)
	return e
}

unix_seconds :: proc(t: time.Time) -> f64 {
	return f64(time.to_unix_seconds(t))
}

canvas_dimensions :: proc(cfg: Terminal_Config, lines: []Line, term_w, term_h: int) -> (int, int) {
	width: int
	if cfg.canvas_width > 0 {
		width = cfg.canvas_width
	} else if cfg.canvas_width == 0 {
		width = term_w
	} else {
		input_width := 0
		for l in lines do input_width = max(input_width, l.width)
		width = cfg.ignore_terminal_dimensions ? input_width : min(term_w, input_width)
	}
	height: int
	if cfg.canvas_height > 0 {
		height = cfg.canvas_height
	} else if cfg.canvas_height == 0 {
		height = term_h
	} else {
		input_height := len(lines)
		if cfg.ignore_terminal_dimensions {
			height = input_height
		} else if cfg.wrap_text {
			height = min(wrapped_line_count(lines, width), term_h)
		} else {
			height = min(term_h, input_height)
		}
	}
	return height, width
}

wrapped_line_count :: proc(lines: []Line, width: int) -> int {
	count := 0
	for l in lines {
		remaining := l.width
		for remaining > width {
			count += 1
			remaining -= width
		}
		count += 1
	}
	return count
}

canvas_dimensions_from_widths :: proc(
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
		count := 0
		for line_width in line_widths {
			remaining := line_width
			for remaining > width {
				count += 1
				remaining -= width
			}
			count += 1
		}
		height = min(count, term_h)
	} else {
		height = min(term_h, input_height)
	}
	return height, width
}

resize_layout_changed :: proc(e: ^Engine, term_w, term_h: int) -> bool {
	canvas_h, canvas_w := canvas_dimensions_from_widths(
		e.cfg,
		e.input_line_widths[:],
		term_w,
		term_h,
	)
	canvas := canvas_make(canvas_h, canvas_w)
	col_offset, row_offset := 0, 0
	visible_top, visible_bottom, visible_right, visible_left: int
	layout_term_w, layout_term_h := term_w, term_h
	if e.cfg.ignore_terminal_dimensions {
		layout_term_w, layout_term_h = canvas.right, canvas.top
	} else {
		col_offset, row_offset = canvas_offsets(e.cfg, canvas, term_w, term_h)
	}
	visible_top = min(canvas.top + row_offset, layout_term_h)
	visible_bottom = max(canvas.bottom + row_offset, 1)
	visible_right = min(canvas.right + col_offset, layout_term_w)
	visible_left = max(canvas.left + col_offset, 1)
	return(
		canvas.top != e.canvas.top ||
		canvas.right != e.canvas.right ||
		col_offset != e.col_offset ||
		row_offset != e.row_offset ||
		visible_top != e.visible_top ||
		visible_bottom != e.visible_bottom ||
		visible_right != e.visible_right ||
		visible_left != e.visible_left \
	)
}

resize_settled :: proc(e: ^Engine) -> bool {
	if take_resize_signal() do e.resize_seen_at = time.tick_now()
	seen, has_seen := e.resize_seen_at.?
	if !has_seen || time.duration_milliseconds(time.tick_since(seen)) < 50 do return false
	e.resize_seen_at = nil
	if e.cfg.ignore_terminal_dimensions do return false
	term_w, term_h := terminal_dimensions()
	if term_w == e.terminal_width && term_h == e.terminal_height do return false
	return resize_layout_changed(e, term_w, term_h)
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

// ---------------------------------------------------------------------------
// input preprocessing — plain text; escape sequences skipped, cursor moves
// honored, no SGR state tracked.
// ---------------------------------------------------------------------------

Line :: struct {
	cells: [dynamic]rune,
	width: int,
}

preprocess_input :: proc(input: string, tab_width: int) -> []Line {
	lines: [dynamic]Line
	append(&lines, Line{})
	row, col := 0, 0

	ensure :: proc(lines: ^[dynamic]Line, row, col: int) {
		for len(lines^) <= row do append(lines, Line{})
		l := &lines^[row]
		for len(l.cells) <= col do append(&l.cells, ' ')
	}

	runes := to_runes(input)
	i := 0
	for i < len(runes) {
		r := runes[i]
		if r == '\x1b' {
			end := skip_escape(runes, i)
			if end < 0 {
				i += 1
				continue
			}
			if runes[i + 1] == '[' && end - 1 > i + 1 {
				final := runes[end - 1]
				params := runes[i + 2:end - 1]
				d := csi_default_param(params)
				switch final {
				case 'A':
					row = max(0, row - d)
				case 'B':
					row += d
				case 'C':
					col += d
				case 'D':
					col = max(0, col - d)
				case 'E':
					row += d; col = 0
				case 'F':
					row = max(0, row - d); col = 0
				case 'G':
					col = max(0, d - 1)
				case 'H', 'f':
					row = max(0, csi_param(params, 0) - 1)
					col = max(0, csi_param(params, 1) - 1)
				}
			}
			i = end
			continue
		}
		if r == '\n' {
			row += 1
			col = 0
			ensure(&lines, row, 0)
			i += 1
			continue
		}
		if r == '\r' {
			col = 0
			i += 1
			continue
		}
		count := 1
		symbol := r
		if r == '\t' {
			symbol = ' '
			count = tab_width - col % tab_width
		}
		for _ in 0 ..< count {
			ensure(&lines, row, col)
			lines[row].cells[col] = symbol
			col += 1
		}
		i += 1
	}

	for &l in lines do l.width = len(l.cells)
	for &l in lines {
		for l.width > 0 && l.cells[l.width - 1] == ' ' do l.width -= 1
	}
	for len(lines) > 0 && lines[len(lines) - 1].width == 0 do pop(&lines)
	if len(lines) == 0 do append(&lines, Line{width = 0})
	return lines[:]
}

to_runes :: proc(s: string) -> []rune {
	out: [dynamic]rune
	for r in s do append(&out, r)
	return out[:]
}

skip_escape :: proc(runes: []rune, start: int) -> int {
	if start + 1 >= len(runes) do return -1
	if runes[start + 1] == ']' {
		t := start + 2
		for t < len(runes) && runes[t] != '\x07' do t += 1
		if t < len(runes) do return t + 1
		return -1
	}
	if runes[start + 1] == '[' {
		t := start + 2
		for t < len(runes) && runes[t] >= '\x30' && runes[t] <= '\x3f' do t += 1
		for t < len(runes) && runes[t] >= '\x20' && runes[t] <= '\x2f' do t += 1
		if t < len(runes) && runes[t] >= '\x40' && runes[t] <= '\x7e' do return t + 1
		return -1
	}
	if runes[start + 1] != '\n' do return start + 2
	return -1
}

csi_param :: proc(params: []rune, index: int) -> int {
	field := 0
	value := 0
	has := false
	for r in params {
		if r == ';' {
			if field == index do return has ? value : 1
			field += 1
			value, has = 0, false
		} else if r >= '0' && r <= '9' {
			value = value * 10 + int(r - '0')
			has = true
		}
	}
	if field == index do return has ? value : 1
	return 1
}

csi_default_param :: proc(params: []rune) -> int {
	return max(csi_param(params, 0), 1)
}

// ---------------------------------------------------------------------------
// character setup
// ---------------------------------------------------------------------------

setup_input_characters :: proc(e: ^Engine, lines: []Line) {
	formatted := lines
	wrapped: [dynamic]Line
	if e.cfg.wrap_text {
		for line in lines {
			current := line
			for current.width > e.canvas.right {
				part: Line
				part.cells = make([dynamic]rune, e.canvas.right)
				copy(part.cells[:], current.cells[:e.canvas.right])
				part.width = e.canvas.right
				append(&wrapped, part)
				remainder := make([dynamic]rune, len(current.cells) - e.canvas.right)
				copy(remainder[:], current.cells[e.canvas.right:])
				current.cells = remainder
				current.width -= e.canvas.right
			}
			append(&wrapped, current)
		}
		formatted = wrapped[:]
	}

	input_height := len(formatted)
	for line, row_index in formatted {
		for col0 in 0 ..< line.width {
			r := line.cells[col0]
			id := e.next_character_id
			e.next_character_id += 1
			if r == ' ' {
				// upstream allocates ids for spaces too; they become fills
				continue
			}
			sym := rune_to_string(r)
			c: Character
			c.character_id = id
			c.input_symbol = sym
			c.input_coord = coord(col0 + 1, input_height - row_index)
			c.current_coord = c.input_coord
			c.visual.symbol = sym
			append(&e.chars, c)
			append(&e.character_sets.input, Char_Id(len(e.chars) - 1))
		}
	}
	anchor_text(e, e.character_sets.input[:], e.cfg.anchor_text)
}

rune_to_string :: proc(r: rune) -> string {
	bytes, n := utf8.encode_rune(r)
	// string([]byte) aliases the backing array, so copy off the stack
	out := make([]byte, n)
	copy(out, bytes[:n])
	return string(out)
}

anchor_text :: proc(e: ^Engine, characters: []Char_Id, anchor: Anchor) {
	if len(characters) == 0 do return
	input_width, input_height := 0, 0
	for id in characters {
		p := e.chars.input_coord[id]
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
			row_delta = e.canvas.center_row - math.floor_div(input_height, 2)
		case .Nw, .N, .Ne:
			row_delta = e.canvas.top - input_height
		case .Sw, .S, .Se:
			row_delta = e.canvas.bottom - 1
		}
	}
	for id in characters {
		p := e.chars.input_coord[id]
		p.column += col_delta
		p.row += row_delta
		e.chars.input_coord[id] = p
		e.chars.current_coord[id] = p
	}
	first := true
	for id in characters {
		p := e.chars.input_coord[id]
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

make_fill_characters :: proc(e: ^Engine) {
	for row in 1 ..= e.canvas.top {
		for column in 1 ..= e.canvas.right {
			if e.render_cells[(row - 1) * e.canvas.right + (column - 1)] >= 0 do continue
			id := e.next_character_id
			e.next_character_id += 1
			c: Character
			c.character_id = id
			c.input_symbol = " "
			c.input_coord = coord(column, row)
			c.current_coord = c.input_coord
			c.is_fill = true
			c.visual.symbol = " "
			append(&e.chars, c)
			if canvas_in_text(e.canvas, coord(column, row)) {
				append(&e.character_sets.inner_fill, Char_Id(len(e.chars) - 1))
			} else {
				append(&e.character_sets.outer_fill, Char_Id(len(e.chars) - 1))
			}
		}
	}
}

add_character :: proc(e: ^Engine, symbol: string, position: Coord) -> Char_Id {
	c: Character
	c.character_id = e.next_character_id
	e.next_character_id += 1
	c.input_symbol = symbol
	c.input_coord = position
	c.current_coord = position
	c.visual.symbol = symbol
	append(&e.chars, c)
	id := Char_Id(len(e.chars) - 1)
	append(&e.character_sets.added, id)
	return id
}

// ---------------------------------------------------------------------------
// queries — shape sortable rows once, sort them in place, then consume ids.
// ---------------------------------------------------------------------------

Character_Sets :: struct {
	input:      [dynamic]Char_Id,
	inner_fill: [dynamic]Char_Id,
	outer_fill: [dynamic]Char_Id,
	added:      [dynamic]Char_Id,
}

Character_Query :: struct {
	sets:         Character_Sets,
	input_coords: [^]Coord,
	canvas:       Canvas,
}

collect_characters :: proc(q: Character_Query, filter: Character_Filter) -> [dynamic]Char_Id {
	all: [dynamic]Char_Id
	if .Input in filter do append(&all, ..q.sets.input[:])
	if .Inner_Fill in filter do append(&all, ..q.sets.inner_fill[:])
	if .Outer_Fill in filter do append(&all, ..q.sets.outer_fill[:])
	if .Added in filter do append(&all, ..q.sets.added[:])
	return all
}

// Canonical order: (-row, column) — packed into a single non-negative key.
get_characters :: proc(
	q: Character_Query,
	filter: Character_Filter,
	srt: Character_Sort,
) -> [dynamic]Char_Id {
	all := collect_characters(q, filter)
	Sort_Row :: struct {
		id:  Char_Id,
		key: int,
	}
	rows := make([]Sort_Row, len(all))
	defer delete(rows)
	// key = (max_row - row) * width + column, dense pass over the SOA fields
	width := q.canvas.right + 1
	top := q.canvas.top
	for id, i in all {
		p := q.input_coords[id]
		rows[i] = {id, (top - p.row) * width + p.column}
	}
	slice.sort_by(rows, proc(a, b: Sort_Row) -> bool {return a.key < b.key})
	for row, i in rows do all[i] = row.id
	if srt == .Random do rand.shuffle(all[:])
	return all
}

// A span is a range into a flat pool — slices for transient views, this
// struct for spans that live inside other state.
Span :: struct {
	start, len: int,
}

span_slice :: proc(pool: []$T, sp: Span) -> []T {
	return pool[sp.start:sp.start + sp.len]
}

// Groups are one flat character pool with explicit spans into that pool.
Char_Groups :: struct {
	members: [dynamic]Char_Id,
	spans:   [dynamic]Span,
}

group_members :: proc(g: Char_Groups, i: int) -> []Char_Id {
	return span_slice(g.members[:], g.spans[i])
}

groups_delete :: proc(g: ^Char_Groups) {
	delete(g.members[:])
	delete(g.spans[:])
}

get_characters_grouped :: proc(
	q: Character_Query,
	filter: Character_Filter,
	grouping: Character_Group,
) -> Char_Groups {
	all := collect_characters(q, filter)
	defer delete(all[:])

	Group_Row :: struct {
		id:         Char_Id,
		group_key:  int,
		within_key: int,
	}
	rows := make([]Group_Row, len(all))
	defer delete(rows)

	reverse_groups :=
		grouping == .Column_R2L ||
		grouping == .Row_T2B ||
		grouping == .Diagonal_TR2BL ||
		grouping == .Diagonal_BR2TL ||
		grouping == .Outside_Center
	width := q.canvas.right + 1
	for id, i in all {
		p := q.input_coords[id]
		k: int
		switch grouping {
		case .Column_L2R, .Column_R2L:
			k = p.column
		case .Row_T2B, .Row_B2T:
			k = p.row
		case .Diagonal_BL2TR, .Diagonal_TR2BL:
			k = p.row + p.column
		case .Diagonal_TL2BR, .Diagonal_BR2TL:
			k = p.column - p.row
		case .Center_Outside, .Outside_Center:
			k = abs(p.column - q.canvas.text_center.column) + abs(p.row - q.canvas.text_center.row)
		}
		if reverse_groups do k = -k
		rows[i] = {id, k, p.row * width + p.column}
	}
	slice.sort_by(rows, proc(a, b: Group_Row) -> bool {
		if a.group_key != b.group_key do return a.group_key < b.group_key
		return a.within_key < b.within_key
	})

	out: Char_Groups
	reserve(&out.members, len(rows))
	reserve(&out.spans, len(rows))
	group_start := 0
	for row, i in rows {
		append(&out.members, row.id)
		if i > 0 && row.group_key != rows[i - 1].group_key {
			append(&out.spans, Span{group_start, i - group_start})
			group_start = i
		}
	}
	if len(rows) > 0 do append(&out.spans, Span{group_start, len(rows) - group_start})
	return out
}

// ---------------------------------------------------------------------------
// rendering & tty
// ---------------------------------------------------------------------------

EMPTY_CELL :: i32(-1)

paint_render_character :: #force_inline proc(
	render_cells: []i32,
	visible: [^]bool,
	coords: [^]Coord,
	layers, character_ids: [^]int,
	i, width: int,
	row_offset, col_offset: int,
	visible_bottom, visible_top, visible_left, visible_right: int,
) {
	if !visible[i] do return
	row := coords[i].row + row_offset
	col := coords[i].column + col_offset
	if row < visible_bottom || row > visible_top || col < visible_left || col > visible_right do return
	cell := &render_cells[(row - 1) * width + (col - 1)]
	if cell^ == EMPTY_CELL {
		cell^ = i32(i)
	} else {
		p := int(cell^)
		layer_i, id_i := layers[i], character_ids[i]
		layer_p, id_p := layers[p], character_ids[p]
		if layer_i > layer_p || (layer_i == layer_p && id_i > id_p) do cell^ = i32(i)
	}
}

update_render_cells :: proc(e: ^Engine, candidates: []Char_Id = nil) -> (int, int) {
	width := max(e.visible_right, 0)
	height := max(e.visible_top, 0)
	cells := width * height
	assert(len(e.render_cells) >= cells)
	render_cells := e.render_cells[:cells]
	for i in 0 ..< cells do render_cells[i] = EMPTY_CELL
	// dense SOA scan: visibility, position, painter key are field arrays.
	visible := e.chars.is_visible[:]
	coords := e.chars.current_coord[:]
	layers := e.chars.layer[:]
	character_ids := e.chars.character_id[:]
	if candidates == nil {
		for i in 0 ..< len(e.chars) {
			paint_render_character(
				render_cells,
				visible,
				coords,
				layers,
				character_ids,
				i,
				width,
				e.row_offset,
				e.col_offset,
				e.visible_bottom,
				e.visible_top,
				e.visible_left,
				e.visible_right,
			)
		}
	} else {
		for id in candidates {
			paint_render_character(
				render_cells,
				visible,
				coords,
				layers,
				character_ids,
				int(id),
				width,
				e.row_offset,
				e.col_offset,
				e.visible_bottom,
				e.visible_top,
				e.visible_left,
				e.visible_right,
			)
		}
	}
	return width, height
}

// A stable character can still change its terminal bytes: color effects and
// scene playback commonly update a visual in place. The cell id alone is not
// a sufficient dirty key, so compare its visual with the per-character code
// cache used by the renderer.
render_cell_dirty :: #force_inline proc(
	cell, previous_cell: i32,
	visuals, cached: [^]Visual,
) -> bool {
	if cell != previous_cell do return true
	if cell == EMPTY_CELL do return false
	id := int(cell)
	return visuals[id] != cached[id]
}

// Build the frame into e.out_buf, top row first.
frame_build :: proc(e: ^Engine, candidates: []Char_Id = nil) {
	width, height := update_render_cells(e, candidates)
	buf := &e.out_buf
	clear(buf)
	min_cap := width * height
	if cap(buf^) < min_cap do reserve(buf, min_cap)
	visuals := e.chars.visual
	render_codes := e.chars.render_code
	render_code_lens := e.chars.render_code_len
	cached := e.chars.cached
	previous := e.previous_cells[:width * height]
	cursor_row, cursor_column := 0, 0
	for screen_row in 0 ..< height {
		row_index := height - 1 - screen_row
		row_cells := e.render_cells[row_index * width:(row_index + 1) * width]
		previous_row := previous[row_index * width:(row_index + 1) * width]
		column := 0
		for column < width {
			for column < width {
				if render_cell_dirty(row_cells[column], previous_row[column], visuals, cached) {
					break
				}
				column += 1
			}
			if column == width do break

			if screen_row > cursor_row {
				append(buf, '\x1b', '[')
				buf_append_decimal(buf, screen_row - cursor_row)
				append(buf, 'E') // cursor next line(s), column 1
				cursor_row, cursor_column = screen_row, 0
			}
			if column > cursor_column {
				append(buf, '\x1b', '[')
				buf_append_decimal(buf, column - cursor_column)
				append(buf, 'C')
				cursor_column = column
			}

			for column < width &&
			    render_cell_dirty(row_cells[column], previous_row[column], visuals, cached) {
				cell := row_cells[column]
				previous_row[column] = cell
				if cell == EMPTY_CELL {
					append(buf, ' ')
				} else {
					id := int(cell)
					visual := visuals[id]
					symbol := visual.symbol
					if e.cfg.no_color {
						append(buf, ..transmute([]byte)symbol)
						continue
					}
					fg, bg, bold := visual.fg, visual.bg, visual.bold
					if visual != cached[id] {
						code: [dynamic; 64]byte
						styled := false
						if bold {
							append(&code, ..transmute([]byte)ANSI_BOLD)
							styled = true
						}
						if fg != nil {
							buf_append_sgr_color(&code, 38, fg.?)
							styled = true
						}
						if bg != nil {
							buf_append_sgr_color(&code, 48, bg.?)
							styled = true
						}
						append(&code, ..transmute([]byte)symbol)
						if styled do append(&code, ..transmute([]byte)ANSI_RESET_ALL)
						// A visual is one UTF-8 rune (at most four bytes) plus two
						// truecolor SGR sequences, bold, and reset: < 64 bytes by the
						// parser's symbol contract. Keep this structural bound checked.
						assert(len(code) <= len(render_codes[id]))
						copy(render_codes[id][:], code[:])
						render_code_lens[id] = u8(len(code))
						cached[id] = visual
					}
					code_len := int(render_code_lens[id])
					append(buf, ..render_codes[id][:code_len])
				}
				column += 1
				cursor_column += 1
			}
		}
	}
}

prep_canvas :: proc(reuse_canvas: bool, move_to_top: string, visible_right, visible_top: int) {
	os.write_string(os.stdout, ANSI_HIDE_CURSOR)
	if reuse_canvas do os.write_string(os.stdout, move_to_top)
	blank := strings.repeat(" ", max(visible_right, 0))
	defer delete(blank)
	for _ in 0 ..< visible_top {
		os.write_string(os.stdout, blank)
		os.write_string(os.stdout, "\n")
	}
	os.write_string(os.stdout, ANSI_SAVE_CURSOR)
}

print_frame :: proc(move_to_top: string, output: []byte) {
	os.write_string(os.stdout, move_to_top)
	os.write(os.stdout, output)
	os.flush(os.stdout)
}

// A settled resize ends the current run. Keep the cursor hidden and return to
// the top of the old drawing area so the replacement engine draws in place.
reset_canvas_area :: proc(visible_top: int) {
	os.write_string(os.stdout, ANSI_RESTORE_CURSOR)
	if visible_top > 0 do os.write_string(os.stdout, move_cursor_up(visible_top))
	os.write_string(os.stdout, ANSI_CLEAR_TO_END)
	os.flush(os.stdout)
}

restore_cursor :: proc(no_restore_cursor, no_eol: bool) {
	if !no_restore_cursor do os.write_string(os.stdout, ANSI_SHOW_CURSOR)
	if !no_eol do os.write_string(os.stdout, "\n")
	os.flush(os.stdout)
}

enforce_framerate :: proc(e: ^Engine) {
	if e.frame_rate == 0 do return
	frame_delay := 1.0 / f64(e.frame_rate)
	elapsed := time.duration_seconds(time.tick_since(e.last_print))
	if elapsed < frame_delay do time.sleep(time.Duration((frame_delay - elapsed) * 1e9))
	e.last_print = time.tick_now()
}

// ---------------------------------------------------------------------------
// winsize via core:sys/linux ioctl
// ---------------------------------------------------------------------------

Winsize :: struct {
	row, col:       u16,
	xpixel, ypixel: u16,
}

ioctl_winsize :: proc(fd: int) -> (int, int) {
	ws: Winsize
	ret := linux.ioctl(linux.Fd(fd), u32(linux.TIOCGWINSZ), uintptr(&ws))
	if int(ret) == 0 do return int(ws.col), int(ws.row)
	return 0, 0
}
