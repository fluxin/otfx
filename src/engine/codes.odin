package engine

import "core:strings"

Visual_Id :: distinct u32
NO_VISUAL :: Visual_Id(0)

// Each cell occupies a fixed row slot: SGR prefix, four glyph bytes, reset.
// NUL fills unused bytes without advancing the terminal cursor.
Cell_Bytes :: 51
Glyph_Bytes :: 4

Packet_Field :: enum {
	Symbol,
	Foreground,
	Background,
	Bold,
}
Packet_Fields :: bit_set[Packet_Field]
All_Packet_Fields :: Packet_Fields{.Symbol, .Foreground, .Background, .Bold}

// Fixed-width SGR fields allow setters to overwrite bytes without shifting.
Packet_Template :: "\x1b[22m\x1b[0000000000000039m\x1b[0000000000000049m"
#assert(len(Packet_Template) == 43)

get_visual :: #force_inline proc(e: ^Engine, id: Particle_Id) -> Visual {
	return e.visuals[e.particles[id].visual_id - 1]
}

packet_decimal :: #force_inline proc(bytes: []byte, v: u8) {
	bytes[0] = '0' + v / 100
	bytes[1] = '0' + (v / 10) % 10
	bytes[2] = '0' + v % 10
}

packet_color :: proc(bytes: []byte, color: Maybe(Color), background, xterm: bool) {
	if c, ok := color.?; ok {
		copy(bytes[:19], "\x1b[38;2;000;000;000m")
		if background do bytes[2] = '4'
		if xterm {
			bytes[5] = '5'
			for &b in bytes[7:18] do b = '0'
			packet_decimal(bytes[15:18], color_to_xterm(c))
		} else {
			packet_decimal(bytes[7:10], c.r)
			packet_decimal(bytes[11:14], c.g)
			packet_decimal(bytes[15:18], c.b)
		}
	} else {
		copy(bytes[:19], "\x1b[0000000000000039m")
		if background do bytes[16] = '4'
	}
}

packet_update :: #force_inline proc(
	bytes: []byte,
	v: ^Visual,
	cfg: ^Terminal_Config,
	fields: Packet_Fields,
	colors: ^Visual = nil,
) {
	colors := v if colors == nil else colors
	fields := fields
	prefix := len(bytes) - Glyph_Bytes
	if !cfg.no_color {
		prefix = 43
		styled := colors.bold || colors.fg != nil || colors.bg != nil
		if styled != (bytes[0] == '\x1b') {
			if styled {
				copy(bytes[:43], Packet_Template)
				copy(bytes[47:51], "\x1b[0m")
			} else {
				for &b in bytes[:43] do b = 0
				for &b in bytes[47:] do b = 0
			}
			fields = All_Packet_Fields
		}
		if styled {
			if .Bold in fields {
				bytes[2], bytes[3] = '0', '1'
				if !colors.bold do bytes[2], bytes[3] = '2', '2'
			}
			if .Foreground in fields do packet_color(bytes[5:24], colors.fg, false, cfg.xterm_colors)
			if .Background in fields do packet_color(bytes[24:43], colors.bg, true, cfg.xterm_colors)
		}
	}
	if .Symbol in fields {
		glyph := bytes[prefix:prefix + Glyph_Bytes]
		for &b in glyph do b = 0
		if len(v.symbol) <= Glyph_Bytes do copy(glyph, v.symbol)
	}
}

// Appearance setters patch the row's winning cell directly. Placement changes
// defer encoding until composition has resolved the new occupants.
update_packet :: #force_inline proc(e: ^Engine, id: Particle_Id, fields: Packet_Fields) {
	if !e.particles[id].is_visible do return
	coord := e.particles[id].current_coord
	y, x := coord.row + e.layout.row_offset, coord.column + e.layout.col_offset
	if y < e.layout.visible_bottom ||
	   y > e.layout.visible_top ||
	   x < e.layout.visible_left ||
	   x > e.layout.visible_right {return}
	row := &e.rows[e.layout.visible_top - y]
	if .Placement in row.flags do return
	cell := (e.layout.visible_top - y) * e.layout.visible_right + x - 1
	if e.frame_particles[cell] != id do return
	stride := cell_bytes(e)
	write_cell(e, id, row.bytes[(x - 1) * stride:x * stride], fields)
	row.flags += {.Appearance}
	if len(get_visual(e, id).symbol) > Glyph_Bytes do row.flags += {.Long_Symbol}
}

write_cell :: #force_inline proc(
	e: ^Engine,
	id: Particle_Id,
	bytes: []byte,
	fields: Packet_Fields,
) {
	visual := &e.visuals[e.particles[id].visual_id - 1]
	colors := visual
	if e.particles[id].preserve_initial_colors do colors = &e.visuals[e.particles[id].initial_visual_id - 1]
	packet_update(bytes, visual, &e.cfg, fields, colors)
}

visual_pool_init :: proc(e: ^Engine) {
	e.visual_ids = make(map[Visual]Visual_Id, 64)
	reserve(&e.visuals, max(e.canvas.top * e.canvas.right * 2, 64))
}

prepare_visual :: proc(e: ^Engine, visual: Visual) -> Visual_Id {
	if id, ok := e.visual_ids[visual]; ok do return id
	append(&e.visuals, visual)
	assert(u64(len(e.visuals)) <= u64(max(u32)))
	id := Visual_Id(len(e.visuals))
	e.visual_ids[visual] = id
	return id
}

// Select a prepared appearance and update its visible row slot.
set_visual_prepared :: #force_inline proc(e: ^Engine, id: Particle_Id, visual_id: Visual_Id) {
	assert(visual_id != NO_VISUAL)
	if e.particles[id].visual_id == visual_id do return
	e.particles[id].visual_id = visual_id
	update_packet(e, id, All_Packet_Fields)
}

// A shared palette entry is immutable. Independent edits reuse the particle's
// preallocated mutable slot; the row owns the encoded bytes.
edit_visual :: #force_inline proc(e: ^Engine, id: Particle_Id) -> ^Visual {
	own := e.particles[id].mutable_visual_id
	entry := &e.visuals[own - 1]
	if e.particles[id].visual_id == own do return entry
	entry^ = e.visuals[e.particles[id].visual_id - 1]
	e.particles[id].visual_id = own
	return entry
}

set_visual_value :: proc(e: ^Engine, id: Particle_Id, value: Visual) {
	old := &e.visuals[e.particles[id].visual_id - 1]
	fields: Packet_Fields
	if !symbol_equal(old.symbol, value.symbol) do fields |= {.Symbol}
	if old.fg != value.fg do fields |= {.Foreground}
	if old.bg != value.bg do fields |= {.Background}
	if old.bold != value.bold do fields |= {.Bold}
	if fields == {} do return
	entry := edit_visual(e, id)
	entry^ = value
	update_packet(e, id, fields)
}

set_visual :: proc {
	set_visual_prepared,
	set_visual_value,
}

set_symbol :: #force_inline proc(e: ^Engine, id: Particle_Id, value: string) {
	if symbol_equal(e.visuals[e.particles[id].visual_id - 1].symbol, value) do return
	entry := edit_visual(e, id)
	entry.symbol = value
	update_packet(e, id, {.Symbol})
}

set_foreground :: #force_inline proc(e: ^Engine, id: Particle_Id, value: Maybe(Color)) {
	if e.visuals[e.particles[id].visual_id - 1].fg == value do return
	entry := edit_visual(e, id)
	entry.fg = value
	update_packet(e, id, {.Foreground})
}

set_background :: #force_inline proc(e: ^Engine, id: Particle_Id, value: Maybe(Color)) {
	if e.visuals[e.particles[id].visual_id - 1].bg == value do return
	entry := edit_visual(e, id)
	entry.bg = value
	update_packet(e, id, {.Background})
}

set_bold :: #force_inline proc(e: ^Engine, id: Particle_Id, value: bool) {
	if e.visuals[e.particles[id].visual_id - 1].bold == value do return
	entry := edit_visual(e, id)
	entry.bold = value
	update_packet(e, id, {.Bold})
}

// Preview uses the same encoder without changing the retained row.
write_particle :: proc(e: ^Engine, id: Particle_Id, b: ^strings.Builder) {
	storage: [Cell_Bytes]byte
	bytes := storage[:cell_bytes(e)]
	write_cell(e, id, bytes, All_Packet_Fields)
	symbol := get_visual(e, id).symbol
	if len(symbol) <= Glyph_Bytes {
		strings.write_bytes(b, bytes)
	} else {
		prefix := 0 if e.cfg.no_color else 43
		strings.write_bytes(b, bytes[:prefix])
		strings.write_string(b, symbol)
		strings.write_bytes(b, bytes[prefix + Glyph_Bytes:])
	}
}
// Repeated IDs retain their ordered scalar semantics.
set_visuals :: proc(e: ^Engine, ids: []Particle_Id, visuals: []Visual_Id) {
	assert(len(ids) == len(visuals))
	for id, i in ids do set_visual(e, id, visuals[i])
}

get_initial_visual :: #force_inline proc(e: ^Engine, id: Particle_Id) -> Visual {
	return e.visuals[e.particles[id].initial_visual_id - 1]
}

// Each particle owns one mutable entry. Prepared and initial entries may be
// shared, but editing one particle never mutates another particle's bytes.
init_particle_visual :: proc(e: ^Engine, id: Particle_Id, initial: Visual) {
	e.particles[id].initial_visual_id = prepare_visual(e, initial)
	append(&e.visuals, Visual{symbol = initial.symbol})
	e.particles[id].visual_id = Visual_Id(len(e.visuals))
	e.particles[id].mutable_visual_id = e.particles[id].visual_id
}

// Cold consumers can request the resolved value; the frame writer borrows bytes.
get_render_visual :: proc(e: ^Engine, id: Particle_Id) -> Visual {
	v := get_visual(e, id)
	if e.particles[id].preserve_initial_colors {
		initial := get_initial_visual(e, id)
		v.fg, v.bg, v.bold = initial.fg, initial.bg, initial.bold
	}
	return v
}
