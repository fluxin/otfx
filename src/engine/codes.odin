package engine

import "core:strings"

Visual_Id :: distinct u32
NO_VISUAL :: Visual_Id(0)

// Complete writable ANSI packet for the common one-rune appearance. Long
// symbols borrow their string between the same prefix and reset slices.
Packet :: struct {
	bytes:          [52]byte,
	prefix, length: u8,
}
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

Visual_Entry :: struct {
	visual: Visual,
	packet: Packet,
}

get_visual :: #force_inline proc(e: ^Engine, id: Particle_Id) -> Visual {
	return e.visuals[e.particles[id].visual_id - 1].visual
}

packet_decimal :: #force_inline proc(bytes: []byte, v: u8) {
	bytes[0] = '0' + v / 100
	bytes[1] = '0' + (v / 10) % 10
	bytes[2] = '0' + v % 10
}

packet_color :: proc(bytes: []byte, color: Maybe(Color), background, xterm: bool) {
	if c, ok := color.?; ok {
		copy(bytes, "\x1b[38;2;000;000;000m")
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
		copy(bytes, "\x1b[0000000000000039m")
		if background do bytes[16] = '4'
	}
}

packet_update :: #force_inline proc(
	p: ^Packet,
	v: ^Visual,
	cfg: ^Terminal_Config,
	fields: Packet_Fields,
	colors: ^Visual = nil,
) {
	colors := v if colors == nil else colors
	fields := fields
	styled := !cfg.no_color && (colors.bold || colors.fg != nil || colors.bg != nil)
	prefix := 43 if styled else 0
	if int(p.prefix) != prefix {
		if styled do copy(p.bytes[:], Packet_Template)
		p.prefix = u8(prefix)
		fields = All_Packet_Fields
	}
	if styled {
		if .Bold in fields {
			p.bytes[2], p.bytes[3] = '0', '1'
			if !colors.bold do p.bytes[2], p.bytes[3] = '2', '2'
		}
		if .Foreground in fields do packet_color(p.bytes[5:24], colors.fg, false, cfg.xterm_colors)
		if .Background in fields do packet_color(p.bytes[24:43], colors.bg, true, cfg.xterm_colors)
	}
	if .Symbol in fields {
		count := len(v.symbol) if len(v.symbol) <= 4 else 0
		copy(p.bytes[prefix:prefix + count], v.symbol[:count])
		end := prefix + count
		if styled {
			copy(p.bytes[end:end + 4], "\x1b[0m")
			end += 4
		}
		p.length = u8(end)
	}
}

update_packet :: #force_inline proc(e: ^Engine, id: Particle_Id, fields: Packet_Fields) {
	dirty_particle_row(e, id)
	entry := &e.visuals[e.particles[id].visual_id - 1]
	colors := &entry.visual
	if e.particles[id].preserve_initial_colors do colors = &e.visuals[e.particles[id].initial_visual_id - 1].visual
	packet_update(&entry.packet, &entry.visual, &e.cfg, fields, colors)
}

visual_pool_init :: proc(e: ^Engine) {
	e.visual_ids = make(map[Visual]Visual_Id, 64)
	reserve(&e.visuals, max(e.canvas.top * e.canvas.right * 2, 64))
}

prepare_visual :: proc(e: ^Engine, visual: Visual) -> Visual_Id {
	if id, ok := e.visual_ids[visual]; ok do return id
	entry := Visual_Entry {
		visual = visual,
	}
	packet_update(&entry.packet, &entry.visual, &e.cfg, All_Packet_Fields)
	append(&e.visuals, entry)
	assert(u64(len(e.visuals)) <= u64(max(u32)))
	id := Visual_Id(len(e.visuals))
	e.visual_ids[visual] = id
	return id
}

// Switching a prepared appearance changes only the reference.
set_visual_prepared :: #force_inline proc(e: ^Engine, id: Particle_Id, visual_id: Visual_Id) {
	assert(visual_id != NO_VISUAL)
	if e.particles[id].visual_id == visual_id do return
	if e.particles[id].preserve_initial_colors {
		source := &e.visuals[visual_id - 1].visual
		target := &e.visuals[e.particles[id].mutable_visual_id - 1].visual
		target^ = source^
		e.particles[id].visual_id = e.particles[id].mutable_visual_id
		update_packet(e, id, All_Packet_Fields)
	} else {
		e.particles[id].visual_id = visual_id
		dirty_particle_row(e, id)
	}
}

// A shared palette entry is immutable. Independent edits reuse the particle's
// preallocated mutable slot; ordinary edits never copy a whole visual/packet.
edit_visual :: #force_inline proc(e: ^Engine, id: Particle_Id) -> (^Visual_Entry, Packet_Fields) {
	own := e.particles[id].mutable_visual_id
	entry := &e.visuals[own - 1]
	if e.particles[id].visual_id == own do return entry, {}
	entry.visual = e.visuals[e.particles[id].visual_id - 1].visual
	e.particles[id].visual_id = own
	return entry, All_Packet_Fields
}

set_visual_value :: proc(e: ^Engine, id: Particle_Id, value: Visual) {
	old := &e.visuals[e.particles[id].visual_id - 1].visual
	fields: Packet_Fields
	if !symbol_equal(old.symbol, value.symbol) do fields |= {.Symbol}
	if old.fg != value.fg do fields |= {.Foreground}
	if old.bg != value.bg do fields |= {.Background}
	if old.bold != value.bold do fields |= {.Bold}
	if fields == {} do return
	entry, inherited := edit_visual(e, id)
	entry.visual = value
	update_packet(e, id, fields | inherited)
}

set_visual :: proc {
	set_visual_prepared,
	set_visual_value,
}

set_symbol :: #force_inline proc(e: ^Engine, id: Particle_Id, value: string) {
	if symbol_equal(e.visuals[e.particles[id].visual_id - 1].visual.symbol, value) do return
	entry, fields := edit_visual(e, id)
	entry.visual.symbol = value
	update_packet(e, id, fields | {.Symbol})
}

set_foreground :: #force_inline proc(e: ^Engine, id: Particle_Id, value: Maybe(Color)) {
	if e.visuals[e.particles[id].visual_id - 1].visual.fg == value do return
	entry, fields := edit_visual(e, id)
	entry.visual.fg = value
	update_packet(e, id, fields | {.Foreground})
}

set_background :: #force_inline proc(e: ^Engine, id: Particle_Id, value: Maybe(Color)) {
	if e.visuals[e.particles[id].visual_id - 1].visual.bg == value do return
	entry, fields := edit_visual(e, id)
	entry.visual.bg = value
	update_packet(e, id, fields | {.Background})
}

set_bold :: #force_inline proc(e: ^Engine, id: Particle_Id, value: bool) {
	if e.visuals[e.particles[id].visual_id - 1].visual.bold == value do return
	entry, fields := edit_visual(e, id)
	entry.visual.bold = value
	update_packet(e, id, fields | {.Bold})
}

// Rendering borrows packets; it performs no appearance assembly or encoding.
append_packet :: #force_inline proc(e: ^Engine, id: Particle_Id) {
	p := &e.visuals[e.particles[id].visual_id - 1].packet
	symbol := e.visuals[e.particles[id].visual_id - 1].visual.symbol
	if len(symbol) <= 4 {
		append(&e.output_parts, p.bytes[:int(p.length)])
	} else {
		if p.prefix != 0 do append(&e.output_parts, p.bytes[:int(p.prefix)])
		append(&e.output_parts, transmute([]byte)symbol)
		if p.prefix != 0 do append(&e.output_parts, transmute([]byte)string("\x1b[0m"))
	}
}

// Preview borrows the same packet used by frame output.
write_particle :: proc(e: ^Engine, id: Particle_Id, b: ^strings.Builder) {
	p := &e.visuals[e.particles[id].visual_id - 1].packet
	symbol := e.visuals[e.particles[id].visual_id - 1].visual.symbol
	if len(symbol) <= 4 {
		strings.write_bytes(b, p.bytes[:int(p.length)])
	} else {
		strings.write_bytes(b, p.bytes[:int(p.prefix)])
		strings.write_string(b, symbol)
		if p.prefix != 0 do strings.write_string(b, "\x1b[0m")
	}
}
// Repeated IDs retain their ordered scalar semantics.
set_visuals :: proc(e: ^Engine, ids: []Particle_Id, visuals: []Visual_Id) {
	assert(len(ids) == len(visuals))
	for id, i in ids do set_visual(e, id, visuals[i])
}

get_initial_visual :: #force_inline proc(e: ^Engine, id: Particle_Id) -> Visual {
	return e.visuals[e.particles[id].initial_visual_id - 1].visual
}

// Each particle owns one mutable entry. Prepared and initial entries may be
// shared, but editing one particle never mutates another particle's bytes.
init_particle_visual :: proc(e: ^Engine, id: Particle_Id, initial: Visual) {
	e.particles[id].initial_visual_id = prepare_visual(e, initial)
	append(&e.visuals, Visual_Entry{visual = Visual{symbol = initial.symbol}})
	e.particles[id].visual_id = Visual_Id(len(e.visuals))
	e.particles[id].mutable_visual_id = e.particles[id].visual_id
	update_packet(e, id, All_Packet_Fields)
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
