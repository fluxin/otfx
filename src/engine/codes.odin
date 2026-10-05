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
	shared := e.particles.shared_appearance_id[id]
	if shared != NO_APPEARANCE do return e.shared_appearances[shared - 1]
	return e.particles.private_appearance[id]
}

get_initial_appearance :: #force_inline proc(e: ^Engine, id: Particle_Id) -> Appearance #no_bounds_check {
	return e.shared_appearances[e.particles.initial_appearance_id[id] - 1]
}

get_render_appearance :: #force_inline proc(e: ^Engine, id: Particle_Id) -> ^Appearance #no_bounds_check {
	shared := e.particles.shared_appearance_id[id]
	if (.Preserve_Initial_Colors in e.particles.flags[id]) do shared = e.particles.initial_appearance_id[id]
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
) #no_bounds_check {
	assert(appearance_id != NO_APPEARANCE && int(appearance_id) <= len(e.shared_appearances))
	// Shared appearances never change once prepared, so the same ID is a no-op.
	if e.particles.shared_appearance_id[id] == appearance_id do return
	queue_particle(e, id, .Content_Changed)
	e.particles.shared_appearance_id[id] = appearance_id
}

// A local style edit detaches only appearance; glyph edits keep sharing intact.
edit_appearance :: #force_inline proc(e: ^Engine, id: Particle_Id) -> ^Appearance #no_bounds_check {
	shared := e.particles.shared_appearance_id[id]
	if shared != NO_APPEARANCE {
		e.particles.private_appearance[id] = e.shared_appearances[shared - 1]
		e.particles.shared_appearance_id[id] = NO_APPEARANCE
	}
	return &e.particles.private_appearance[id]
}

set_appearance_value :: #force_inline proc(e: ^Engine, id: Particle_Id, value: Appearance) #no_bounds_check {
	old := get_appearance(e, id)
	if old.colors == value.colors && old.bold == value.bold do return
	queue_particle(e, id, .Content_Changed)
	e.particles.shared_appearance_id[id] = NO_APPEARANCE
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

// Bold, then each set color lane as one fixed-width SGR field. Every styled
// cell ends in a reset, so unset lanes need no field at all.
PREFIX_MAX :: len("\x1b[1m") + 2 * len("\x1b[38;2;000;000;000m")
// A cell slot holds the prefix, one UTF-8 glyph, and the reset.
SLOT_MAX :: PREFIX_MAX + 4 + len("\x1b[0m")

@(private = "file", rodata)
Decimal_Triplets := [256][3]byte {
	"000", "001", "002", "003", "004", "005", "006", "007",
	"008", "009", "010", "011", "012", "013", "014", "015",
	"016", "017", "018", "019", "020", "021", "022", "023",
	"024", "025", "026", "027", "028", "029", "030", "031",
	"032", "033", "034", "035", "036", "037", "038", "039",
	"040", "041", "042", "043", "044", "045", "046", "047",
	"048", "049", "050", "051", "052", "053", "054", "055",
	"056", "057", "058", "059", "060", "061", "062", "063",
	"064", "065", "066", "067", "068", "069", "070", "071",
	"072", "073", "074", "075", "076", "077", "078", "079",
	"080", "081", "082", "083", "084", "085", "086", "087",
	"088", "089", "090", "091", "092", "093", "094", "095",
	"096", "097", "098", "099", "100", "101", "102", "103",
	"104", "105", "106", "107", "108", "109", "110", "111",
	"112", "113", "114", "115", "116", "117", "118", "119",
	"120", "121", "122", "123", "124", "125", "126", "127",
	"128", "129", "130", "131", "132", "133", "134", "135",
	"136", "137", "138", "139", "140", "141", "142", "143",
	"144", "145", "146", "147", "148", "149", "150", "151",
	"152", "153", "154", "155", "156", "157", "158", "159",
	"160", "161", "162", "163", "164", "165", "166", "167",
	"168", "169", "170", "171", "172", "173", "174", "175",
	"176", "177", "178", "179", "180", "181", "182", "183",
	"184", "185", "186", "187", "188", "189", "190", "191",
	"192", "193", "194", "195", "196", "197", "198", "199",
	"200", "201", "202", "203", "204", "205", "206", "207",
	"208", "209", "210", "211", "212", "213", "214", "215",
	"216", "217", "218", "219", "220", "221", "222", "223",
	"224", "225", "226", "227", "228", "229", "230", "231",
	"232", "233", "234", "235", "236", "237", "238", "239",
	"240", "241", "242", "243", "244", "245", "246", "247",
	"248", "249", "250", "251", "252", "253", "254", "255",
}

packet_decimal :: #force_inline proc(bytes: []byte, v: u8) #no_bounds_check {
	triplet := Decimal_Triplets[v]
	bytes[0] = triplet[0]
	bytes[1] = triplet[1]
	bytes[2] = triplet[2]
}

packet_color :: #force_inline proc(bytes: []byte, c: Color, background, xterm: bool) -> int #no_bounds_check {
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
	return packet_write(bytes, e.particles.symbol[id], appearance, &e.cfg)
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
	length := packet_write(bytes[:], e.particles.symbol[id], &appearance, &e.cfg)
	strings.write_bytes(b, bytes[:length])
}
