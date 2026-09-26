package engine

import "base:intrinsics"
import "core:c/libc"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:terminal/ansi"
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
	xterm_colors:               bool,
	no_color:                   bool,
	existing_color_handling:    Existing_Color_Handling,
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
	virtual_clock:              bool,
	terminal_background_color:  Color,
}

// Existing input colors are either ignored, held at the renderer boundary, or
// consumed by an effect's own final lanes. Dynamic intentionally stays an
// effect decision: a global override would hide temporary effect visuals.
Existing_Color_Handling :: enum {
	Ignore,
	Always,
	Dynamic,
}

existing_color_handling_parse :: proc(s: string) -> (Existing_Color_Handling, bool) {
	switch s {
	case "ignore":
		return .Ignore, true
	case "always":
		return .Always, true
	case "dynamic":
		return .Dynamic, true
	}
	return .Ignore, false
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

// Dynamic color handling is an input-style data transform, not a timeline.
// Effects own when they call these helpers; they simply avoid repeating the
// same nullable FG/BG writes in every direct next loop.
dynamic_apply_input_colors :: #force_inline proc(visual: ^Visual, input: Visual) {
	visual.fg = input.fg
	visual.bg = input.bg
}

// Lerp both source colour lanes with the established, stepped gradient rule.
// The caller owns the tick-to-step conversion and all phase lifetime policy.
dynamic_gradient_to_input :: #force_inline proc(
	visual: ^Visual,
	start: Color,
	input: Visual,
	steps, step: int,
) {
	if fg, ok := input.fg.?; ok {
		visual.fg = gradient_between_step(start, fg, steps, step)
	} else {
		visual.fg = nil
	}
	if bg, ok := input.bg.?; ok {
		visual.bg = gradient_between_step(start, bg, steps, step)
	} else {
		visual.bg = nil
	}
}

// Binarypath's collapse target is the source style darkened in both lanes.
// Keep that exceptional transform here rather than open-coding nullable lanes.
dynamic_gradient_to_dimmed_input :: #force_inline proc(
	visual: ^Visual,
	start: Color,
	input: Visual,
	brightness: f64,
	steps, step: int,
) {
	if fg, ok := input.fg.?; ok {
		visual.fg = gradient_between_step(
			start,
			adjust_color_brightness(fg, brightness),
			steps,
			step,
		)
	} else {
		visual.fg = nil
	}
	if bg, ok := input.bg.?; ok {
		visual.bg = gradient_between_step(
			start,
			adjust_color_brightness(bg, brightness),
			steps,
			step,
		)
	} else {
		visual.bg = nil
	}
}

Frame :: struct {
	visual:   Visual,
	duration: int,
}

// Effect-owned frame lanes use this contiguous SoA storage. Construction is
// shared; each effect owns activation, tick arithmetic, and completion.
Frame_Timeline :: #soa[dynamic]Frame

timeline_append_frame :: #force_inline proc(
	frames: ^Frame_Timeline,
	visual: Visual,
	duration: int,
) {
	assert(duration >= 1)
	append(frames, Frame{visual, duration})
}

create_hold_timeline :: proc(
	frames: ^Frame_Timeline,
	visual: Visual,
	duration, count: int,
) -> Span {
	assert(count >= 1)
	start := len(frames^)
	for _ in 0 ..< count do timeline_append_frame(frames, visual, duration)
	return {start, count}
}

create_gradient_timeline :: proc(
	frames: ^Frame_Timeline,
	symbol: string,
	duration: int,
	start, end: Color,
	steps: int,
) -> Span {
	assert(steps >= 1)
	timeline_start := len(frames^)
	for step in 0 ..= steps {
		timeline_append_frame(
			frames,
			Visual{symbol, gradient_between_step(start, end, steps, step), nil, false},
			duration,
		)
	}
	return {timeline_start, steps + 1}
}

create_timeline :: proc {
	create_hold_timeline,
	create_gradient_timeline,
}

// Renderer-owned admission state for effects that return a candidate slice.
Frame_Selection :: enum u8 {
	Absent,
	Present,
	Pending,
}

Particle :: struct {
	initial_visual_id:       Visual_Id,
	initial_coord:           Coord,
	is_visible:              bool,
	is_fill:                 bool,
	layer:                   int,
	current_coord:           Coord,
	// One logical appearance for both prepared and dynamic publication.
	visual_id:               Visual_Id,
	mutable_visual_id:       Visual_Id,
	preserve_initial_colors: bool,
	frame_selection:         Frame_Selection,
}

Particle_Storage :: #soa[dynamic]Particle

// ---------------------------------------------------------------------------
// engine world
// ---------------------------------------------------------------------------

Particle_Id :: distinct int

Particle_Kind :: enum {
	Input,
	Inner_Fill,
	Outer_Fill,
}

Particle_Filter :: bit_set[Particle_Kind;u8]

PARTICLE_FILTER_INPUT :: Particle_Filter{.Input}
PARTICLE_FILTER_ALL_FILLS :: Particle_Filter{.Input, .Inner_Fill, .Outer_Fill}

Particle_Sort :: enum {
	Top_Bottom_Left_Right,
	Random,
}

Particle_Group :: enum {
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

group_parse :: proc(s: string) -> (Particle_Group, bool) {
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

Render_Layout :: struct {
	visible_top, visible_bottom: int,
	visible_right, visible_left: int,
	col_offset, row_offset:      int,
}

Engine :: struct {
	cfg:               Terminal_Config,
	canvas:            Canvas,
	terminal_width:    int,
	terminal_height:   int,
	input_line_widths: [dynamic]int,
	resize_seen_at:    Maybe(time.Tick),
	particles:         Particle_Storage, // struct-of-arrays arena
	mono_start:        time.Tick,
	particle_sets:     Particle_Sets,
	layout:            Render_Layout,
	frame_particles:   []Particle_Id,
	dirty_rows:        []bool,
	blank_row:         []byte,
	visual_ids:        map[Visual]Visual_Id,
	visuals:           [dynamic]Visual_Entry,
	output_parts:      [dynamic][]byte,
	capture_buf:       [dynamic]byte,
	last_print:        time.Tick,
	logical_frame:     int,
}

// Frames per second that logical time advances at when the clock is virtual and
// output is unpaced. It only has to be the rate a viewer would have watched at.
Virtual_Frame_Rate :: 60

// One logical frame per effect step. Effects never call this themselves; the
// step entry point owns it so every consumer advances the same way.
clock_advance :: #force_inline proc(e: ^Engine) {
	e.logical_frame += 1
}

// Effects that budget a phase in seconds read time through here. Under a
// virtual clock the elapsed time is a function of the frames produced, so an
// effect's duration stops depending on how fast the host can render it -- which
// is what makes an unpaced capture (docs previews, parity dumps) reproducible.
elapsed_seconds :: proc(e: ^Engine) -> f64 {
	if e.cfg.virtual_clock {
		rate := e.cfg.frame_rate if e.cfg.frame_rate > 0 else Virtual_Frame_Rate
		return f64(e.logical_frame) / f64(rate)
	}
	return time.duration_seconds(time.tick_since(e.mono_start))
}

terminal_dimensions :: proc() -> (int, int) {
	buf: [256]u8
	c, cok := strconv.parse_int(os.get_env_buf(buf[:], "COLUMNS"))
	l, lok := strconv.parse_int(os.get_env_buf(buf[:], "LINES"))
	if cok && lok do return int(c), int(l)
	w, h := ioctl_winsize(1) // stdout
	if cok do w = int(c)
	if lok do h = int(l)
	if w <= 0 do w = 80
	if h <= 0 do h = 24
	return w, h
}

Input_Error :: enum {
	None,
	Invalid_Tab_Width,
	Unsupported_Escape,
	Unsupported_SGR,
	Unsupported_Cursor,
}

engine_make :: proc(
	input: string,
	cfg: Terminal_Config,
	formatted_allocator: mem.Allocator,
) -> (
	Engine,
	Input_Error,
) {
	e: Engine
	e.cfg = cfg
	e.mono_start = time.tick_now()
	e.last_print = time.tick_now()

	input_text := input
	if input_text == "" {
		input_text = "No Input."
	}
	lines, input_error := preprocess_input(input_text, cfg.tab_width)
	if input_error != .None do return {}, input_error
	e.input_line_widths = make([dynamic]int, len(lines))
	for line, i in lines do e.input_line_widths[i] = line.width

	term_w, term_h := terminal_dimensions()
	e.terminal_width, e.terminal_height = term_w, term_h
	e.canvas, e.layout = layout_make(cfg, e.input_line_widths[:], term_w, term_h)
	width, height := max(e.layout.visible_right, 0), max(e.layout.visible_top, 0)
	e.frame_particles = make([]Particle_Id, width * height)
	e.dirty_rows = make([]bool, height)
	for &dirty in e.dirty_rows do dirty = true
	e.blank_row = make([]byte, width)
	for &b in e.blank_row do b = ' '
	reserve(&e.output_parts, width * height * 4 + height)
	visual_pool_init(&e)
	setup_input_particles(&e, lines)
	// drop characters that landed outside the canvas (same as upstream)
	write := 0
	for id in e.particle_sets.input {
		p := e.particles.initial_coord[id]
		if canvas_in(e.canvas, p) {
			e.particle_sets.input[write] = id
			write += 1
		}
	}
	resize(&e.particle_sets.input, write)
	// A construction-only occupancy bitmap identifies fill cells. It is not
	// retained renderer state and is released before playback.
	occupied := make([]bool, e.canvas.top * e.canvas.right)
	for id in e.particle_sets.input {
		c := e.particles.initial_coord[id]
		occupied[(c.row - 1) * e.canvas.right + c.column - 1] = true
	}
	make_fill_particles(&e, occupied)
	delete(occupied)
	return e, .None
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

resize_layout_changed :: proc(e: ^Engine, term_w, term_h: int) -> bool {
	canvas, layout := layout_make(e.cfg, e.input_line_widths[:], term_w, term_h)
	return canvas.top != e.canvas.top || canvas.right != e.canvas.right || layout != e.layout
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
// input preprocessing — a small build-time terminal which captures terminal
// SGR state alongside each cell. The hot animation/render loops only read the
// resulting immutable columns.
// ---------------------------------------------------------------------------

Input_Cell :: struct {
	symbol: rune,
	style:  Visual,
}

Line :: struct {
	cells: [dynamic]Input_Cell,
	width: int,
}

input_style_has_color :: #force_inline proc(style: Visual) -> bool {
	return style.fg != nil || style.bg != nil
}

preprocess_input :: proc(input: string, tab_width: int) -> ([]Line, Input_Error) {
	if tab_width <= 0 do return nil, .Invalid_Tab_Width
	lines: [dynamic]Line
	append(&lines, Line{})
	row, col := 0, 0
	active: Visual
	standard_fg: Maybe(int)

	ensure :: proc(lines: ^[dynamic]Line, row, col: int) {
		for len(lines^) <= row do append(lines, Line{})
		l := &lines^[row]
		for len(l.cells) <= col do append(&l.cells, Input_Cell{symbol = ' '})
	}

	runes := to_runes(input)
	defer delete(runes)
	i := 0
	for i < len(runes) {
		r := runes[i]
		if r == '\x1b' {
			if i + 1 >= len(runes) || runes[i + 1] != '[' {
				return nil, .Unsupported_Escape
			}
			end := input_csi_end(runes, i)
			if end == 0 do return nil, .Unsupported_Cursor
			final := runes[end - 1]
			params_end := i + 2
			for params_end < end - 1 &&
			    runes[params_end] >= '\x30' &&
			    runes[params_end] <= '\x3f' {
				params_end += 1
			}
			params := runes[i + 2:params_end]
			intermediates := runes[params_end:end - 1]
			if final == 'm' {
				if len(intermediates) != 0 || !input_apply_sgr(params, &active, &standard_fg) {
					return nil, .Unsupported_SGR
				}
			} else if !input_private_mode(params, intermediates, final) {
				if !input_apply_cursor(params, intermediates, final, &row, &col) {
					return nil, .Unsupported_Cursor
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
			lines[row].cells[col] = {symbol, active}
			col += 1
		}
		i += 1
	}

	for &l in lines do l.width = len(l.cells)
	for &l in lines {
		for l.width > 0 {
			last := l.cells[l.width - 1]
			if last.symbol != ' ' || input_style_has_color(last.style) do break
			l.width -= 1
		}
	}
	for len(lines) > 0 && lines[len(lines) - 1].width == 0 do pop(&lines)
	if len(lines) == 0 do append(&lines, Line{width = 0})
	return lines[:], .None
}

to_runes :: proc(s: string) -> []rune {
	out: [dynamic]rune
	for r in s do append(&out, r)
	return out[:]
}

// The caller admits only ESC [. Zero denotes an incomplete or malformed CSI.
input_csi_end :: proc(runes: []rune, start: int) -> int {
	t := start + 2
	for t < len(runes) && runes[t] >= '\x30' && runes[t] <= '\x3f' do t += 1
	for t < len(runes) && runes[t] >= '\x20' && runes[t] <= '\x2f' do t += 1
	if t < len(runes) && runes[t] >= '\x40' && runes[t] <= '\x7e' do return t + 1
	return 0
}

input_private_mode :: proc(params, intermediates: []rune, final: rune) -> bool {
	if len(intermediates) != 0 || len(params) != 3 || params[0] != '?' do return false
	if final != 'h' && final != 'l' do return false
	return (params[1] == '2' && params[2] == '5') || (params[1] == '7' && params[2] == '0')
}

input_apply_cursor :: proc(params, intermediates: []rune, final: rune, row, col: ^int) -> bool {
	if len(intermediates) != 0 || (len(params) > 0 && params[0] == '?') do return false
	for p in params {
		if (p < '0' || p > '9') && p != ';' do return false
	}
	d := csi_default_param(params)
	switch final {
	case 'A':
		row^ = max(0, row^ - d)
	case 'B':
		row^ += d
	case 'C':
		col^ += d
	case 'D':
		col^ = max(0, col^ - d)
	case 'E':
		row^ += d; col^ = 0
	case 'F':
		row^ = max(0, row^ - d); col^ = 0
	case 'G':
		col^ = max(0, d - 1)
	case 'H', 'f':
		row^ = max(0, csi_param(params, 0) - 1)
		col^ = max(0, csi_param(params, 1) - 1)
	case:
		return false
	}
	return true
}

input_apply_sgr :: proc(params: []rune, active: ^Visual, standard_fg: ^Maybe(int)) -> bool {
	values: [dynamic]int
	defer delete(values[:])
	if len(params) == 0 {
		append(&values, 0)
	} else {
		value := 0
		for p in params {
			if p == ';' {
				append(&values, value)
				value = 0
			} else if p >= '0' && p <= '9' {
				value = value * 10 + int(p - '0')
			} else {
				return false
			}
		}
		append(&values, value)
	}

	i := 0
	for i < len(values) {
		p := values[i]
		switch {
		case p == 0:
			active^ = {}
			standard_fg^ = nil
		case p == 1:
			active.bold = true
			if standard, ok := standard_fg^.?; ok do active.fg = xterm_to_rgb(u8(standard - 30 + 8))
		case p == 22:
			active.bold = false
			if standard, ok := standard_fg^.?; ok do active.fg = xterm_to_rgb(u8(standard - 30))
		case p == 39:
			active.fg = nil
			standard_fg^ = nil
		case p == 49:
			active.bg = nil
		case p >= 30 && p <= 37:
			active.fg = xterm_to_rgb(u8(p - 30 + (active.bold ? 8 : 0)))
			standard_fg^ = p
		case p >= 90 && p <= 97:
			active.fg = xterm_to_rgb(u8(p - 90 + 8))
			standard_fg^ = nil
		case p >= 40 && p <= 47:
			active.bg = xterm_to_rgb(u8(p - 40))
		case p >= 100 && p <= 107:
			active.bg = xterm_to_rgb(u8(p - 100 + 8))
		case p == 38 || p == 48:
			if i + 1 >= len(values) do return false
			is_fg := p == 38
			mode := values[i + 1]
			color: Color
			switch mode {
			case 5:
				if i + 2 >= len(values) || values[i + 2] < 0 || values[i + 2] > 255 do return false
				color = xterm_to_rgb(u8(values[i + 2]))
				i += 2
			case 2:
				if i + 4 >= len(values) do return false
				for component in values[i + 2:i + 5] {
					if component < 0 || component > 255 do return false
				}
				color = {u8(values[i + 2]), u8(values[i + 3]), u8(values[i + 4])}
				i += 4
			case:
				return false
			}
			if is_fg {
				active.fg = color
				standard_fg^ = nil
			} else {
				active.bg = color
			}
		}
		i += 1
	}
	return true
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

setup_input_particles :: proc(e: ^Engine, lines: []Line) {
	// The decoded input already gives the population. Allocate/zero the SoA
	// columns once instead of growing and scattering a complete row per glyph.
	count := 0
	for line in lines {
		for cell in line.cells[:line.width] {
			if cell.symbol != ' ' || input_style_has_color(cell.style) do count += 1
		}
	}
	first := len(e.particles)
	set_first := len(e.particle_sets.input)
	resize(&e.particles, first + count)
	resize(&e.particle_sets.input, set_first + count)
	written := 0
	// Wrap by walking the original cells. No copied lines or retained suffixes.
	wrap_width := max(e.canvas.right, 1)
	input_height := len(lines)
	if e.cfg.wrap_text do input_height = wrapped_line_count(e.input_line_widths[:], wrap_width)
	row_index := 0
	for line in lines {
		column := 0
		for col0 in 0 ..< line.width {
			if e.cfg.wrap_text && column == wrap_width {
				column = 0
				row_index += 1
			}
			column += 1
			cell := line.cells[col0]
			if cell.symbol == ' ' && !input_style_has_color(cell.style) {
				continue
			}
			sym := rune_to_string(cell.symbol)
			id := first + written
			e.particles.initial_coord[id] = coord(column, input_height - row_index)
			e.particles.current_coord[id] = e.particles.initial_coord[id]
			initial := cell.style
			initial.symbol = sym
			e.particles.preserve_initial_colors[id] = e.cfg.existing_color_handling == .Always
			init_particle_visual(e, Particle_Id(id), initial)
			e.particle_sets.input[set_first + written] = Particle_Id(id)
			written += 1
		}
		row_index += 1
	}
	anchor_text(e, e.particle_sets.input[:], e.cfg.anchor_text)
}

rune_to_string :: proc(r: rune) -> string {
	bytes, n := utf8.encode_rune(r)
	// string([]byte) aliases the backing array, so copy off the stack
	out := make([]byte, n)
	copy(out, bytes[:n])
	return string(out)
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
			row_delta = e.canvas.center_row - math.floor_div(input_height, 2)
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

make_fill_particles :: proc(e: ^Engine, occupied: []bool) {
	count := 0
	for cell in occupied {
		if !cell do count += 1
	}
	first := len(e.particles)
	resize(&e.particles, first + count)
	written := 0
	for row in 1 ..= e.canvas.top {
		for column in 1 ..= e.canvas.right {
			if occupied[(row - 1) * e.canvas.right + column - 1] do continue
			id := first + written
			e.particles.initial_coord[id] = coord(column, row)
			e.particles.current_coord[id] = e.particles.initial_coord[id]
			e.particles.is_fill[id] = true
			init_particle_visual(e, Particle_Id(id), Visual{symbol = " "})
			written += 1
			if canvas_in_text(e.canvas, coord(column, row)) {
				append(&e.particle_sets.inner_fill, Particle_Id(id))
			} else {
				append(&e.particle_sets.outer_fill, Particle_Id(id))
			}
		}
	}
}

// A build-time batch owns capacity planning. Callers specify the number of
// characters they will create, without reading or sizing engine storage.
Particle_Batch :: struct {
	engine:    ^Engine,
	remaining: int,
}

particle_batch :: proc(e: ^Engine, count: int) -> Particle_Batch {
	assert(count >= 0)
	reserve(&e.particles, len(e.particles) + count)
	reserve(&e.visuals, len(e.visuals) + count * 2)
	return {e, count}
}

add_particle :: proc {
	add_particle_single,
	add_particle_batched,
}

@(private = "file")
add_particle_batched :: #force_inline proc(
	batch: ^Particle_Batch,
	symbol: string,
	position: Coord,
) -> Particle_Id {
	assert(batch.remaining > 0)
	batch.remaining -= 1
	return add_particle_single(batch.engine, symbol, position)
}

@(private = "file")
add_particle_single :: proc(e: ^Engine, symbol: string, position: Coord) -> Particle_Id {
	c: Particle
	c.initial_coord = position
	c.current_coord = position
	append(&e.particles, c)
	id := Particle_Id(len(e.particles) - 1)
	init_particle_visual(e, id, Visual{symbol = symbol})
	return id
}

// ---------------------------------------------------------------------------
// queries — shape sortable rows once, sort them in place, then consume ids.
// ---------------------------------------------------------------------------

Particle_Sets :: struct {
	input:      [dynamic]Particle_Id,
	inner_fill: [dynamic]Particle_Id,
	outer_fill: [dynamic]Particle_Id,
}

Particle_Query :: struct {
	sets:           Particle_Sets,
	initial_coords: []Coord,
	canvas:         Canvas,
}

collect_particles :: proc(q: Particle_Query, filter: Particle_Filter) -> [dynamic]Particle_Id {
	all: [dynamic]Particle_Id
	if .Input in filter do append(&all, ..q.sets.input[:])
	if .Inner_Fill in filter do append(&all, ..q.sets.inner_fill[:])
	if .Outer_Fill in filter do append(&all, ..q.sets.outer_fill[:])
	return all
}

// Canonical order: (-row, column) — packed into a single non-negative key.
get_particles :: proc(
	q: Particle_Query,
	filter: Particle_Filter,
	srt: Particle_Sort,
) -> [dynamic]Particle_Id {
	all := collect_particles(q, filter)
	Sort_Row :: struct {
		id:  Particle_Id,
		key: int,
	}
	rows := make([]Sort_Row, len(all))
	defer delete(rows)
	// key = (max_row - row) * width + column, dense pass over the SOA fields
	width := q.canvas.right + 1
	top := q.canvas.top
	for id, i in all {
		p := q.initial_coords[id]
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
Particle_Groups :: struct {
	members: [dynamic]Particle_Id,
	spans:   [dynamic]Span,
}

group_members :: proc(g: Particle_Groups, i: int) -> []Particle_Id {
	return span_slice(g.members[:], g.spans[i])
}

groups_delete :: proc(g: ^Particle_Groups) {
	delete(g.members[:])
	delete(g.spans[:])
}

get_particles_grouped :: proc(
	q: Particle_Query,
	filter: Particle_Filter,
	grouping: Particle_Group,
) -> Particle_Groups {
	all := collect_particles(q, filter)
	defer delete(all[:])

	Group_Row :: struct {
		id:         Particle_Id,
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
		p := q.initial_coords[id]
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

	out: Particle_Groups
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

symbol_equal :: #force_inline proc(a, b: string) -> bool {
	return len(a) == len(b) && (raw_data(a) == raw_data(b) || a == b)
}

Frame_Origin :: string(ansi.DECRC + ansi.DECSC)

prep_canvas :: proc(reuse_canvas: bool, visible_right, visible_top: int) {
	os.write_string(os.stdout, ansi.CSI + ansi.DECTCEM_HIDE)
	if reuse_canvas do os.write_string(os.stdout, Frame_Origin)
	blank := strings.repeat(" ", max(visible_right, 0))
	defer delete(blank)
	for _ in 0 ..< visible_top {
		os.write_string(os.stdout, blank)
		os.write_string(os.stdout, "\n")
	}
	if visible_top > 0 do os.write_string(os.stdout, move_cursor_up(visible_top))
	os.write_string(os.stdout, ansi.DECSC)
}

// A settled resize ends the current run. Keep the cursor hidden and return to
// the top of the old drawing area so the replacement engine draws in place.
reset_canvas_area :: proc() {
	os.write_string(os.stdout, ansi.DECRC)
	os.write_string(os.stdout, ansi.CSI + "0" + ansi.ED)
	os.flush(os.stdout)
}

restore_cursor :: proc(visible_top: int, no_restore_cursor, no_eol: bool) {
	// The saved position is the canvas top; cleanup moves below the canvas.
	os.write_string(os.stdout, ansi.DECRC)
	if visible_top > 0 do os.write_string(os.stdout, fmt.tprintf("%s%d%s", ansi.CSI, visible_top, ansi.CNL))
	if !no_restore_cursor do os.write_string(os.stdout, ansi.CSI + ansi.DECTCEM_SHOW)
	if !no_eol do os.write_string(os.stdout, "\n")
	os.flush(os.stdout)
}

enforce_framerate :: proc(e: ^Engine) {
	if e.cfg.frame_rate == 0 do return
	frame_delay := 1.0 / f64(e.cfg.frame_rate)
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
