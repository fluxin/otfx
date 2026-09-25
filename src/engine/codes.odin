package engine

// Prepared and dynamic visuals share one encoder and invalidation contract.
// Preparation interns reusable appearances during build. Dynamic appearances
// retain encoded color fragments, without interning or allocating in playback.

import "core:mem"
import "core:simd"
import "core:strings"
import "core:terminal/ansi"

Visual_Code_Id :: distinct u32
NO_CODE :: Visual_Code_Id(0)

// Logical state is always current, regardless of its encoded representation.
get_visual :: #force_inline proc(e: ^Engine, id: Char_Id) -> Visual {
	return e.chars.visual[id]
}

// Whole-value publication shares one column writer. Compare before writing,
// then preserve color fragments when only symbol or bold changes.
@(private = "file")
store_visual :: #force_inline proc(e: ^Engine, id: Char_Id, visual: ^Visual) {
	mem.copy_non_overlapping(&e.chars.visual[id], visual, size_of(Visual))
}

// Cache the variable decimal bytes, not ANSI constants or the existing symbol.
// Two RGB triples need at most 11 bytes each ("255;255;255").
Encoded_Colors :: struct {
	fg, bg:      [11]byte,
	using state: bit_field u16 {
		fg_len: u8   | 4,
		bg_len: u8   | 4,
		valid:  bool | 1,
	},
}
#assert(size_of(Encoded_Colors) == 24)

encode_color :: proc(bytes: []byte, color: Color, xterm: bool) -> u8 {
	builder := strings.builder_from_bytes(bytes)
	if xterm {
		buf_append_decimal(&builder.buf, int(color_to_xterm(color)))
	} else {
		buf_append_decimal(&builder.buf, int(color.r))
		strings.write_byte(&builder, ';')
		buf_append_decimal(&builder.buf, int(color.g))
		strings.write_byte(&builder, ';')
		buf_append_decimal(&builder.buf, int(color.b))
	}
	return u8(strings.builder_len(builder))
}

encode_colors :: proc(cache: ^Encoded_Colors, fg, bg: Maybe(Color), cfg: ^Terminal_Config) {
	cache.fg_len, cache.bg_len = 0, 0
	if color, ok := fg.?; ok do cache.fg_len = encode_color(cache.fg[:], color, cfg.xterm_colors)
	if color, ok := bg.?; ok do cache.bg_len = encode_color(cache.bg[:], color, cfg.xterm_colors)
	cache.valid = true
}

Code_Entry :: struct {
	visual: Visual,
	offset: u32,
	len:    u32,
}

code_pool_init :: proc(e: ^Engine) {
	e.code_ids = make(map[Visual]Visual_Code_Id)
	reserve(&e.code_entries, len(e.chars))
	reserve(&e.code_bytes, len(e.chars) * 24)
}

// Build and playback share the same byte assembler. Symbols already hold UTF-8;
// ANSI syntax is constant, so only color numbers require cached formatting.
write_visual :: proc(
	b: ^strings.Builder,
	symbol: string,
	bold: bool,
	colors: ^Encoded_Colors,
	cfg: ^Terminal_Config,
) {
	if cfg.no_color {
		strings.write_string(b, symbol)
		return
	}
	if bold do strings.write_string(b, ansi.CSI + ansi.BOLD + ansi.SGR)
	if colors.fg_len != 0 {
		strings.write_string(b, cfg.xterm_colors ? "\x1b[38;5;" : "\x1b[38;2;")
		strings.write_bytes(b, colors.fg[:int(colors.fg_len)])
		strings.write_string(b, ansi.SGR)
	}
	if colors.bg_len != 0 {
		strings.write_string(b, cfg.xterm_colors ? "\x1b[48;5;" : "\x1b[48;2;")
		strings.write_bytes(b, colors.bg[:int(colors.bg_len)])
		strings.write_string(b, ansi.SGR)
	}
	strings.write_string(b, symbol)
	if bold || colors.fg_len != 0 || colors.bg_len != 0 {
		strings.write_string(b, ansi.CSI + ansi.RESET + ansi.SGR)
	}
}

// Intern a visual and return its stable code id. Call during effect build for
// any appearance that repeats across characters or frames.
prepare_visual :: proc(e: ^Engine, visual: Visual) -> Visual_Code_Id {
	if id, ok := e.code_ids[visual]; ok do return id
	offset := len(e.code_bytes)
	builder := strings.Builder {
		buf = e.code_bytes,
	}
	colors: Encoded_Colors
	if !e.cfg.no_color do encode_colors(&colors, visual.fg, visual.bg, &e.cfg)
	write_visual(&builder, visual.symbol, visual.bold, &colors, &e.cfg)
	e.code_bytes = builder.buf
	length := len(e.code_bytes) - offset
	assert(u64(len(e.code_bytes)) <= u64(max(u32)))
	assert(u64(len(e.code_entries)) < u64(max(u32)))
	append(&e.code_entries, Code_Entry{visual = visual, offset = u32(offset), len = u32(length)})
	id := Visual_Code_Id(len(e.code_entries))
	e.code_ids[visual] = id
	return id
}

// Prepared publication updates logical state and selects its encoded bytes.
@(private = "file")
set_visual_prepared :: #force_inline proc(e: ^Engine, id: Char_Id, code: Visual_Code_Id) {
	assert(code != NO_CODE)
	prior := e.chars.code[id]
	if prior == code do return
	visual := &e.code_entries[code - 1].visual
	changed := !visual_equal(&e.chars.visual[id], visual)
	store_visual(e, id, visual)
	e.chars.code[id] = code
	e.chars.encoded_colors[id].valid = false
	if changed do raster_mark_visual_change(e, int(id))
}

@(private = "file")
set_visual_value :: #force_inline proc(e: ^Engine, id: Char_Id, visual: Visual) {
	v := visual
	prior := &e.chars.visual[id]
	if visual_equal(prior, &v) do return
	colors_changed :=
		transmute(u32)prior.fg != transmute(u32)v.fg ||
		transmute(u32)prior.bg != transmute(u32)v.bg
	e.chars.code[id] = NO_CODE
	store_visual(e, id, &v)
	if colors_changed do e.chars.encoded_colors[id].valid = false
	raster_mark_visual_change(e, int(id))
}

// Both forms publish logical state and let the engine own its derived bytes.
set_visual :: proc {
	set_visual_value,
	set_visual_prepared,
}

// Bulk prepared appearances use the same ordered publication as set_visual.
// Compare eight code IDs together; held blocks never touch logical appearance
// or dirty state. IDs may be sparse or repeated; changed blocks retain order.
set_visual_codes :: #force_inline proc(e: ^Engine, ids: []Char_Id, codes: []Visual_Code_Id) {
	assert(len(ids) == len(codes))
	base := 0
	for ; base + 8 <= len(ids); base += 8 {
		current: [8]u32
		wanted: [8]u32
		for lane in 0 ..< 8 {
			assert(codes[base + lane] != NO_CODE)
			current[lane] = u32(e.chars.code[ids[base + lane]])
			wanted[lane] = u32(codes[base + lane])
		}
		changed := simd.to_bits(
			simd.lanes_ne(transmute(#simd[8]u32)current, transmute(#simd[8]u32)wanted),
		)
		if changed == 0 do continue
		for lane in 0 ..< 8 do set_visual(e, ids[base + lane], codes[base + lane])
	}
	for i in base ..< len(ids) do set_visual(e, ids[i], codes[i])
}

// External direct writers also use this invalidation before marking membership.
invalidate_visual_bytes :: #force_inline proc(e: ^Engine, id: Char_Id) {
	e.chars.code[id] = NO_CODE
	e.chars.encoded_colors[id].valid = false
}

@(private = "file")
visual_changed :: #force_inline proc(e: ^Engine, id: Char_Id) {
	// Component setters have already released their prepared byte cache.
	e.chars.encoded_colors[id].valid = false
	raster_mark_visual_change(e, int(id))
}

// Preview and frame emission use the same policy-specialized writer.
write_character :: proc(e: ^Engine, id: Char_Id, b: ^strings.Builder) {
	assert(id >= 0 && int(id) < len(e.chars))
	if e.cfg.no_color {
		write_character_mode(e, id, b, .Ignore, true, false)
	} else if e.cfg.existing_color_handling == .Always {
		write_character_mode(e, id, b, .Always, false, false)
	} else {
		write_character_mode(e, id, b, .Ignore, false, false)
	}
}

@(private = "package")
write_character_mode :: #force_inline proc(
	e: ^Engine,
	id: Char_Id,
	b: ^strings.Builder,
	$handling: Existing_Color_Handling,
	$no_color: bool,
	$emitted: bool,
) #no_bounds_check {
	// Frame callers supply retained-raster IDs; preview validates its ID above.
	// Prepared IDs and byte spans are engine-owned, append-only build products.
	code := e.chars.code[id]
	if code != NO_CODE &&
	   (no_color || handling != .Always || !e.chars.uses_input_preexisting_colors[id]) {
		entry := &e.code_entries[code - 1]
		strings.write_bytes(b, e.code_bytes[int(entry.offset):int(entry.offset) + int(entry.len)])
		when emitted do e.chars.cached_code[id] = code
		return
	}
	value := &e.chars.visual[id]
	adjusted: Visual
	if handling == .Always && e.chars.uses_input_preexisting_colors[id] {
		effective_visual_into(&adjusted, value, e.chars.input_style[id], true, handling)
		value = &adjusted
	}
	colors := &e.chars.encoded_colors[id]
	if !no_color && !colors.valid do encode_colors(colors, value.fg, value.bg, &e.cfg)
	write_visual(b, value.symbol, value.bold, colors, &e.cfg)
	when emitted {
		e.chars.cached_code[id] = code
		if code == NO_CODE {
			mem.copy_non_overlapping(&e.chars.cached[id], value, size_of(Visual))
		}
	}
	return
}

set_symbol :: #force_inline proc(e: ^Engine, id: Char_Id, symbol: string) {
	if symbol_equal(get_visual(e, id).symbol, symbol) do return
	e.chars.code[id] = NO_CODE
	e.chars.visual[id].symbol = symbol
	// UTF-8 is already encoded; changing it does not invalidate color numbers.
	raster_mark_visual_change(e, int(id))
}

set_foreground :: #force_inline proc(e: ^Engine, id: Char_Id, color: Maybe(Color)) {
	if get_visual(e, id).fg == color do return
	e.chars.code[id] = NO_CODE
	e.chars.visual[id].fg = color
	visual_changed(e, id)
}

set_background :: #force_inline proc(e: ^Engine, id: Char_Id, color: Maybe(Color)) {
	if get_visual(e, id).bg == color do return
	e.chars.code[id] = NO_CODE
	e.chars.visual[id].bg = color
	visual_changed(e, id)
}

set_bold :: #force_inline proc(e: ^Engine, id: Char_Id, bold: bool) {
	if get_visual(e, id).bold == bold do return
	e.chars.code[id] = NO_CODE
	e.chars.visual[id].bold = bold
	raster_mark_visual_change(e, int(id))
}
