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
	bytes:  [PREFIX_MAX]byte, // encoded style prefix; prepared lazily during rendering
	length: u8, // prefix bytes in use; zero when unstyled or colorless
	dirty:  bool, // prefix needs encoding on its next render
}

Appearance_Id :: distinct u32 // one-based index into shared_appearances
NO_APPEARANCE :: Appearance_Id(0)

get_appearance :: #force_inline proc(e: ^Engine, id: Particle_Id) -> Appearance #no_bounds_check {
	shared := e.particles[id].shared_appearance_id
	if shared != NO_APPEARANCE do return e.shared_appearances[shared - 1]
	return e.particles.private_appearance[id]
}

get_initial_appearance :: #force_inline proc(e: ^Engine, id: Particle_Id) -> Appearance #no_bounds_check {
	return e.shared_appearances[e.particles[id].initial_appearance_id - 1]
}

get_render_appearance :: #force_inline proc(e: ^Engine, id: Particle_Id) -> ^Appearance #no_bounds_check {
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

// Prepared foreground fades from one start color to each final color.
// A step that repeats the previous color reuses its ID, so republishing a
// held step stays a no-op.
Gradient_Steps :: struct {
	codes: []Appearance_Id, // final * (steps + 1) + step
	steps: int,
}

gradient_steps_make :: proc(
	e: ^Engine,
	start: Color,
	finals: []Color,
	steps: int,
	allocator := context.allocator,
) -> Gradient_Steps {
	frames := steps + 1
	codes := make([]Appearance_Id, len(finals) * frames, allocator)
	for final, i in finals {
		previous: Color
		for step in 0 ..< frames {
			fg := gradient_between_step(start, final, steps, step)
			if step > 0 && fg == previous {
				codes[i * frames + step] = codes[i * frames + step - 1]
			} else {
				codes[i * frames + step] = prepare_appearance(e, Appearance{colors = {fg = fg}})
			}
			previous = fg
		}
	}
	return {codes, steps}
}

// The prepared appearance for `step` of the fade to final color `final`.
gradient_step :: #force_inline proc(g: Gradient_Steps, final, step: int) -> Appearance_Id #no_bounds_check {
	return g.codes[final * (g.steps + 1) + step]
}

set_appearance_prepared :: #force_inline proc(
	e: ^Engine,
	id: Particle_Id,
	appearance_id: Appearance_Id,
) #no_bounds_check {
	assert(appearance_id != NO_APPEARANCE && int(appearance_id) <= len(e.shared_appearances))
	// Shared appearances never change once prepared, so the same ID is a no-op.
	if e.particles[id].shared_appearance_id == appearance_id do return
	queue_particle(e, id, .Content_Changed)
	e.particles[id].shared_appearance_id = appearance_id
}

// A local style edit detaches only appearance; glyph edits keep sharing intact.
edit_appearance :: #force_inline proc(e: ^Engine, id: Particle_Id) -> ^Appearance #no_bounds_check {
	shared := e.particles[id].shared_appearance_id
	if shared != NO_APPEARANCE {
		e.particles.private_appearance[id] = e.shared_appearances[shared - 1]
		e.particles[id].shared_appearance_id = NO_APPEARANCE
	}
	return &e.particles.private_appearance[id]
}

set_appearance_value :: #force_inline proc(e: ^Engine, id: Particle_Id, value: Appearance) #no_bounds_check {
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

set_foreground :: #force_inline proc(e: ^Engine, id: Particle_Id, value: Maybe(Color)) #no_bounds_check {
	if get_appearance(e, id).colors.fg == value do return
	queue_particle(e, id, .Content_Changed)
	appearance := edit_appearance(e, id)
	appearance.colors.fg = value
	dirty_appearance(appearance)
}

set_background :: #force_inline proc(e: ^Engine, id: Particle_Id, value: Maybe(Color)) #no_bounds_check {
	if get_appearance(e, id).colors.bg == value do return
	queue_particle(e, id, .Content_Changed)
	appearance := edit_appearance(e, id)
	appearance.colors.bg = value
	dirty_appearance(appearance)
}

set_bold :: #force_inline proc(e: ^Engine, id: Particle_Id, value: bool) #no_bounds_check {
	if get_appearance(e, id).bold == value do return
	queue_particle(e, id, .Content_Changed)
	appearance := edit_appearance(e, id)
	appearance.bold = value
	dirty_appearance(appearance)
}

set_appearances :: proc(e: ^Engine, ids: []Particle_Id, appearances: []Appearance_Id) #no_bounds_check {
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

// Bold, then each set color lane as one fixed-width SGR field. Every styled
// cell ends in a reset, so unset lanes need no field at all.
PREFIX_MAX :: len("\x1b[1m") + 2 * len("\x1b[38;2;000;000;000m")
// A cell slot holds the prefix, one UTF-8 glyph, and the reset.
SLOT_MAX :: PREFIX_MAX + 4 + len("\x1b[0m")

packet_decimal :: #force_inline proc(bytes: []byte, v: u8) {
	bytes[0] = '0' + v / 100
	bytes[1] = '0' + (v / 10) % 10
	bytes[2] = '0' + v % 10
}

packet_color :: proc(bytes: []byte, c: Color, background, xterm: bool) -> int {
	if xterm {
		copy(bytes, "\x1b[38;5;000m")
		if background do bytes[2] = '4'
		packet_decimal(bytes[7:10], color_to_xterm(c))
		return len("\x1b[38;5;000m")
	}
	copy(bytes, "\x1b[38;2;000;000;000m")
	if background do bytes[2] = '4'
	packet_decimal(bytes[7:10], c.r)
	packet_decimal(bytes[11:14], c.g)
	packet_decimal(bytes[15:18], c.b)
	return len("\x1b[38;2;000;000;000m")
}

// Rendering resolves a stale prefix once, after all pending style edits.
encode_appearance :: proc(appearance: ^Appearance, cfg: ^Terminal_Config) #no_bounds_check {
	appearance.dirty = false
	appearance.length = 0
	if cfg.no_color do return
	bytes := appearance.bytes[:]
	length := 0
	if appearance.bold do length += copy(bytes, "\x1b[1m")
	if fg, ok := appearance.colors.fg.?; ok {
		length += packet_color(bytes[length:], fg, false, cfg.xterm_colors)
	}
	if bg, ok := appearance.colors.bg.?; ok {
		length += packet_color(bytes[length:], bg, true, cfg.xterm_colors)
	}
	appearance.length = u8(length)
}

// The caller supplies the cell's slot. No complete packet is stored on a particle.
encode_particle :: proc(e: ^Engine, id: Particle_Id, bytes: []byte) -> int #no_bounds_check {
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
	prefix := 0 if cfg.no_color else int(appearance.length)
	// One checked slice admits the fixed cell slot: the prefix, at most four
	// UTF-8 bytes, and the reset.
	slot := bytes[:SLOT_MAX if prefix != 0 else 4]
	end := prefix
	#no_bounds_check {
		if prefix != 0 do copy(slot[:PREFIX_MAX], appearance.bytes[:])
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
	return end
}

// Preview encodes a local copy; it does not change retained prefixes or dirty state.
write_particle :: proc(e: ^Engine, id: Particle_Id, b: ^strings.Builder) {
	bytes: [SLOT_MAX]byte
	appearance := get_render_appearance(e, id)^
	if appearance.dirty do encode_appearance(&appearance, &e.cfg)
	length := packet_write(bytes[:], e.particles[id].symbol, &appearance, &e.cfg)
	strings.write_bytes(b, bytes[:length])
}
