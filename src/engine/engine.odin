package engine

import "core:container/bit_array"
import "core:time"

// Engine state, construction, and playback time.

Engine :: struct {
	cfg:                   Terminal_Config,
	canvas:                Canvas,
	terminal_width:        int,
	terminal_height:       int,
	input_line_widths:     [dynamic]int,
	resize_seen_at:        Maybe(time.Tick),
	particles:             Particle_Storage, // struct-of-arrays arena
	mono_start:            time.Tick,
	particle_sets:         Particle_Sets,
	layout:                Render_Layout,
	updates:               [dynamic]Particle_Update,
	cells:                 []Render_Cell,
	rows:                  []Render_Row,
	dirty_cells:           bit_array.Bit_Array,
	dirty_rows, emit_rows: bit_array.Bit_Array,
	canvas_bytes:          []byte, // contiguous fixed-width cell slots, borrowed by rows
	cell_stride:           int,
	shared_appearances:    [dynamic]Appearance,
	last_print:            time.Tick,
	logical_frame:         int,
	stats:                 Frame_Stats_State,
}

engine_make :: proc(input: string, cfg: Terminal_Config) -> (Engine, Input_Error) {
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
	e.cells = make([]Render_Cell, width * height)
	for &cell in e.cells do cell.top = -1
	e.rows = make([]Render_Row, height)
	bit_array.init(&e.dirty_cells, width * height)
	bit_array.init(&e.dirty_rows, height)
	bit_array.init(&e.emit_rows, height)
	for &row, i in e.rows {
		row.cells = e.cells[i * width:(i + 1) * width]
		bit_array.set(&e.dirty_rows, i)
	}
	e.cell_stride = 4 if cfg.no_color else 51
	e.canvas_bytes = make([]byte, width * height * e.cell_stride)
	for &cell, i in e.cells {
		cell.bytes = e.canvas_bytes[i * e.cell_stride:(i + 1) * e.cell_stride]
		cell.bytes[0] = ' '
	}
	row_length := width * e.cell_stride
	for &row, i in e.rows do row.bytes = e.canvas_bytes[i * row_length:(i + 1) * row_length]
	reserve(&e.shared_appearances, max(e.canvas.top * e.canvas.right, 64))
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

enforce_framerate :: proc(e: ^Engine) {
	if e.cfg.frame_rate == 0 do return
	frame_delay := 1.0 / f64(e.cfg.frame_rate)
	elapsed := time.duration_seconds(time.tick_since(e.last_print))
	if elapsed < frame_delay do time.sleep(time.Duration((frame_delay - elapsed) * 1e9))
	e.last_print = time.tick_now()
}
