package engine

import "core:container/bit_array"
import "core:mem"
import "core:time"

// Engine state, construction, and playback time.

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
	frame_candidates:  [dynamic]Particle_Id,
	frame_generation:  Frame_Selection,
	dirty_rows:        []bool,
	cell_heads:        []Particle_Id,
	frame_visuals:     []Visual_Id,
	row_bytes:         [][dynamic]byte,
	row_valid:         []bool,
	dirty_cells:       bit_array.Bit_Array,
	row_changes:       []int,
	cell_offsets:      []int,
	blank_row:         []byte,
	visual_ids:        map[Visual]Visual_Id,
	visuals:           [dynamic]Visual_Entry,
	output_parts:      [dynamic][]byte,
	capture_buf:       [dynamic]byte,
	last_print:        time.Tick,
	logical_frame:     int,
	stats:             Frame_Stats_State,
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
	for &id in e.frame_particles do id = -1
	e.dirty_rows = make([]bool, height)
	e.cell_heads = make([]Particle_Id, width * height)
	e.frame_visuals = make([]Visual_Id, width * height)
	e.row_bytes = make([][dynamic]byte, height)
	e.row_valid = make([]bool, height)
	bit_array.init(&e.dirty_cells, width * height)
	e.row_changes = make([]int, height)
	e.cell_offsets = make([]int, (width + 1) * height)
	for &bytes in e.row_bytes do reserve(&bytes, width * size_of(Packet) + 52)
	for &dirty in e.dirty_rows do dirty = true
	e.blank_row = make([]byte, width)
	for &b in e.blank_row do b = ' '
	reserve(&e.output_parts, height * 2 + 1)
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
	reserve(&e.frame_candidates, cap(e.particles))
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
