package engine

import "core:strings"
import "core:unicode/utf8"

// Appearance storage, setters, and cell packet encoding.

Color_Pair :: struct {
	fg: Maybe(Color),
	bg: Maybe(Color),
}

// A shared appearance describes styling only; each particle owns its glyph.
Appearance :: struct {
	colors: Color_Pair,
	bold:   bool,
	bytes:  [43]byte, // encoded style prefix; prepared lazily during rendering
	dirty:  bool, // prefix needs encoding on its next render
}

Appearance_Id :: distinct u32 // one-based index into shared_appearances
NO_APPEARANCE :: Appearance_Id(0)

get_appearance :: #force_inline proc(e: ^Engine, id: Particle_Id) -> Appearance {
	shared := e.particles[id].shared_appearance_id
	if shared != NO_APPEARANCE do return e.shared_appearances[shared - 1]
	return e.particles.private_appearance[id]
}

get_initial_appearance :: #force_inline proc(e: ^Engine, id: Particle_Id) -> Appearance {
	return e.shared_appearances[e.particles[id].initial_appearance_id - 1]
}

get_render_appearance :: #force_inline proc(e: ^Engine, id: Particle_Id) -> ^Appearance {
	shared := e.particles[id].shared_appearance_id
	if (.Preserve_Initial_Colors in e.particles[id].flags) do shared = e.particles[id].initial_appearance_id
	if shared != NO_APPEARANCE do return &e.shared_appearances[shared - 1]
	return &e.particles.private_appearance[id]
}

dirty_appearance :: #force_inline proc(appearance: ^Appearance) {
	appearance.dirty = true
}

// Creation always appends. Sharing is explicit reuse of the returned ID.
prepare_appearance :: proc(e: ^Engine, appearance: Appearance) -> Appearance_Id {
	prepared := Appearance {
		colors = appearance.colors,
		bold   = appearance.bold,
		dirty  = true,
	}
	append(&e.shared_appearances, prepared)
	assert(u64(len(e.shared_appearances)) <= u64(max(u32)))
	return Appearance_Id(len(e.shared_appearances))
}

set_appearance_prepared :: #force_inline proc(
	e: ^Engine,
	id: Particle_Id,
	appearance_id: Appearance_Id,
) {
	assert(appearance_id != NO_APPEARANCE && int(appearance_id) <= len(e.shared_appearances))
	if e.particles[id].shared_appearance_id == appearance_id && !e.shared_appearances[appearance_id - 1].dirty do return
	queue_particle(e, id, .Content_Changed)
	e.particles[id].shared_appearance_id = appearance_id
}

// A local style edit detaches only appearance; glyph edits keep sharing intact.
edit_appearance :: #force_inline proc(e: ^Engine, id: Particle_Id) -> ^Appearance {
	shared := e.particles[id].shared_appearance_id
	if shared != NO_APPEARANCE {
		e.particles.private_appearance[id] = e.shared_appearances[shared - 1]
		e.particles[id].shared_appearance_id = NO_APPEARANCE
	}
	return &e.particles.private_appearance[id]
}

set_appearance_value :: #force_inline proc(e: ^Engine, id: Particle_Id, value: Appearance) {
	old := get_appearance(e, id)
	if old.colors == value.colors && old.bold == value.bold do return
	queue_particle(e, id, .Content_Changed)
	e.particles[id].shared_appearance_id = NO_APPEARANCE
	appearance := &e.particles.private_appearance[id]
	appearance.colors, appearance.bold = value.colors, value.bold
	dirty_appearance(appearance)
}

set_appearance :: proc {
	set_appearance_prepared,
	set_appearance_value,
}

set_foreground :: #force_inline proc(e: ^Engine, id: Particle_Id, value: Maybe(Color)) {
	if get_appearance(e, id).colors.fg == value do return
	queue_particle(e, id, .Content_Changed)
	appearance := edit_appearance(e, id)
	appearance.colors.fg = value
	dirty_appearance(appearance)
}

set_background :: #force_inline proc(e: ^Engine, id: Particle_Id, value: Maybe(Color)) {
	if get_appearance(e, id).colors.bg == value do return
	queue_particle(e, id, .Content_Changed)
	appearance := edit_appearance(e, id)
	appearance.colors.bg = value
	dirty_appearance(appearance)
}

set_bold :: #force_inline proc(e: ^Engine, id: Particle_Id, value: bool) {
	if get_appearance(e, id).bold == value do return
	queue_particle(e, id, .Content_Changed)
	appearance := edit_appearance(e, id)
	appearance.bold = value
	dirty_appearance(appearance)
}

set_appearances :: proc(e: ^Engine, ids: []Particle_Id, appearances: []Appearance_Id) {
	assert(len(ids) == len(appearances))
	for id, i in ids do set_appearance(e, id, appearances[i])
}

// Dynamic color handling is an input-style data transform, not a timeline.
// Effects own when they call these helpers; they simply avoid repeating the
// same nullable FG/BG writes in every direct next loop.
dynamic_apply_input_colors :: #force_inline proc(appearance: ^Appearance, input: Appearance) {
	appearance.colors = input.colors
}

// Lerp both source colour lanes with the established, stepped gradient rule.
// The caller owns the tick-to-step conversion and all phase lifetime policy.
dynamic_gradient_to_input :: #force_inline proc(
	appearance: ^Appearance,
	start: Color,
	input: Appearance,
	steps, step: int,
) {
	if fg, ok := input.colors.fg.?; ok {
		appearance.colors.fg = gradient_between_step(start, fg, steps, step)
	} else {
		appearance.colors.fg = nil
	}
	if bg, ok := input.colors.bg.?; ok {
		appearance.colors.bg = gradient_between_step(start, bg, steps, step)
	} else {
		appearance.colors.bg = nil
	}
}

// Binarypath's collapse target is the source style darkened in both lanes.
// Keep that exceptional transform here rather than open-coding nullable lanes.
dynamic_gradient_to_dimmed_input :: #force_inline proc(
	appearance: ^Appearance,
	start: Color,
	input: Appearance,
	brightness: f64,
	steps, step: int,
) {
	if fg, ok := input.colors.fg.?; ok {
		appearance.colors.fg = gradient_between_step(
			start,
			adjust_color_brightness(fg, brightness),
			steps,
			step,
		)
	} else {
		appearance.colors.fg = nil
	}
	if bg, ok := input.colors.bg.?; ok {
		appearance.colors.bg = gradient_between_step(
			start,
			adjust_color_brightness(bg, brightness),
			steps,
			step,
		)
	} else {
		appearance.colors.bg = nil
	}
}

// Fixed-width SGR fields encode colors without shifting subsequent bytes.
Packet_Template :: "\x1b[22m\x1b[0000000000000039m\x1b[0000000000000049m"
#assert(len(Packet_Template) == 43)

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

// Rendering resolves a stale prefix once, after all pending style edits.
encode_appearance :: proc(appearance: ^Appearance, cfg: ^Terminal_Config) {
	appearance.dirty = false
	if cfg.no_color ||
	   (!appearance.bold && appearance.colors.fg == nil && appearance.colors.bg == nil) {
		appearance.bytes = {}
		return
	}
	bytes := appearance.bytes[:]
	copy(bytes, Packet_Template)
	if appearance.bold do bytes[2], bytes[3] = '0', '1'
	packet_color(bytes[5:24], appearance.colors.fg, false, cfg.xterm_colors)
	packet_color(bytes[24:43], appearance.colors.bg, true, cfg.xterm_colors)
}

// The caller supplies the cell's slot. No complete packet is stored on a particle.
encode_particle :: proc(e: ^Engine, id: Particle_Id, bytes: []byte) -> int {
	appearance := get_render_appearance(e, id)
	if appearance.dirty do encode_appearance(appearance, &e.cfg)
	return packet_write(bytes, e.particles[id].symbol, appearance, &e.cfg)
}

packet_write :: #force_inline proc(
	bytes: []byte,
	symbol: rune,
	appearance: ^Appearance,
	cfg: ^Terminal_Config,
) -> int {
	prefix := 0
	if !cfg.no_color &&
	   (appearance.bold || appearance.colors.fg != nil || appearance.colors.bg != nil) {
		prefix = len(appearance.bytes)
	}
	// One checked slice admits the fixed cell slot. UTF-8 emits at most four
	// bytes; the styled prefix is 43 bytes and the reset is four more (51 total).
	slot := bytes[:51 if prefix != 0 else 4]
	end := prefix
	#no_bounds_check {
		if prefix != 0 do copy(slot[:43], appearance.bytes[:])
		if symbol != 0 {
			encoded, width := utf8.encode_rune(symbol)
			copy(slot[end:end + 4], encoded[:])
			end += width
		}
		if prefix != 0 {
			copy(slot[end:end + 4], "\x1b[0m")
			end += 4
		}
	}
	for &b in bytes[end:] do b = 0
	return end
}

// Preview encodes a local copy; it does not change retained prefixes or dirty state.
write_particle :: proc(e: ^Engine, id: Particle_Id, b: ^strings.Builder) {
	bytes: [51]byte
	appearance := get_render_appearance(e, id)^
	if appearance.dirty do encode_appearance(&appearance, &e.cfg)
	length := packet_write(bytes[:], e.particles[id].symbol, &appearance, &e.cfg)
	strings.write_bytes(b, bytes[:length])
}
