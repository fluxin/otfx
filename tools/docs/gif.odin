package main

import "core:image"
import "core:slice"

// The palette is built from the frames the effect actually produced rather than
// from a fixed cube. Gradient-driven effects walk hundreds of near neighbours,
// and a 6x6x6 cube quantises those into visible bands.
Palette :: [256]image.RGB_Pixel

Palette_Background :: 0 // exact, so large flat areas never drift
Palette_Transparent :: 255 // reserved; unchanged pixels encode to this
Palette_Colors :: Palette_Transparent - 1 // usable median-cut slots

Color_Entry :: struct {
	rgb:   image.RGB_Pixel,
	count: u32,
}

Color_Box :: struct {
	start, end: int,
}

Color_Space :: 1 << 24

// Direct-indexed by packed RGB rather than hashed: a preview walks tens of
// millions of pixels through this, and a map lookup per pixel dominates the
// whole run. The tables are allocated once and shared by every effect.
Quantizer :: struct {
	counts:   []u32,
	lookup:   []u8,
	observed: [dynamic]u32, // distinct keys, so a reset never scans 16M entries
	palette:  Palette,
}

color_key :: #force_inline proc(color: image.RGB_Pixel) -> u32 {
	return u32(color[0]) << 16 | u32(color[1]) << 8 | u32(color[2])
}

// The tables outlive the per-preview arena that is installed while a preview
// renders, so they pin the caller's allocator instead of inheriting whichever
// one happens to be current when a colour is first observed.
quantizer_make :: proc(allocator := context.allocator) -> Quantizer {
	return {
		counts = make([]u32, Color_Space, allocator),
		lookup = make([]u8, Color_Space, allocator),
		observed = make([dynamic]u32, 0, 4096, allocator),
	}
}

quantizer_destroy :: proc(q: ^Quantizer) {
	delete(q.counts)
	delete(q.lookup)
	delete(q.observed)
}

// `lookup` needs no reset: pass two only ever reads keys pass one observed, and
// building the palette rewrites every one of them.
quantizer_reset :: proc(q: ^Quantizer) {
	for key in q.observed do q.counts[key] = 0
	clear(&q.observed)
	q.palette = {}
}

quantizer_observe :: proc(q: ^Quantizer, pixels: []image.RGB_Pixel) {
	for pixel in pixels {
		key := color_key(pixel)
		if q.counts[key] == 0 do append(&q.observed, key)
		q.counts[key] += 1
	}
}

box_channel_range :: proc(entries: []Color_Entry, channel: int) -> (low, high: u8) {
	low, high = 255, 0
	for entry in entries {
		low = min(low, entry.rgb[channel])
		high = max(high, entry.rgb[channel])
	}
	return
}

// Median cut: repeatedly split the box with the widest colour spread along that
// axis, at the count-weighted median, so dense regions of the gradient keep more
// slots than sparse ones.
quantizer_build :: proc(q: ^Quantizer, background: image.RGB_Pixel) {
	entries: [dynamic]Color_Entry
	defer delete(entries)
	background_key := color_key(background)
	for key in q.observed {
		if key == background_key do continue
		append(
			&entries,
			Color_Entry{{u8(key >> 16), u8(key >> 8), u8(key)}, q.counts[key]},
		)
	}
	// Pixel order decides the observation order, and median cut is order
	// sensitive, so entries are sorted before any splitting to keep the palette
	// reproducible across runs.
	slice.sort_by(entries[:], proc(a, b: Color_Entry) -> bool {
		return color_key(a.rgb) < color_key(b.rgb)
	})

	q.palette[Palette_Background] = background
	q.palette[Palette_Transparent] = background
	q.lookup[background_key] = Palette_Background
	if len(entries) == 0 do return

	boxes: [dynamic]Color_Box
	defer delete(boxes)
	append(&boxes, Color_Box{0, len(entries)})

	for len(boxes) < Palette_Colors {
		target, target_channel, target_extent := -1, 0, 0
		for box, index in boxes {
			if box.end - box.start < 2 do continue
			for channel in 0 ..< 3 {
				low, high := box_channel_range(entries[box.start:box.end], channel)
				if int(high) - int(low) > target_extent {
					target, target_channel = index, channel
					target_extent = int(high) - int(low)
				}
			}
		}
		if target < 0 do break

		box := boxes[target]
		span := entries[box.start:box.end]
		sort_entries_by_channel(span, target_channel)

		total: u32
		for entry in span do total += entry.count
		half, running, split := total / 2, u32(0), box.start
		for entry, index in span {
			running += entry.count
			if running > half {
				split = box.start + index
				break
			}
		}
		split = clamp(split, box.start + 1, box.end - 1)
		boxes[target] = Color_Box{box.start, split}
		append(&boxes, Color_Box{split, box.end})
	}

	for box, index in boxes {
		slot := u8(index + 1)
		red, green, blue, weight: u64
		for entry in entries[box.start:box.end] {
			red += u64(entry.rgb[0]) * u64(entry.count)
			green += u64(entry.rgb[1]) * u64(entry.count)
			blue += u64(entry.rgb[2]) * u64(entry.count)
			weight += u64(entry.count)
		}
		if weight == 0 do continue
		q.palette[slot] = {u8(red / weight), u8(green / weight), u8(blue / weight)}
		for entry in entries[box.start:box.end] do q.lookup[color_key(entry.rgb)] = slot
	}
}

sort_entries_by_channel :: proc(entries: []Color_Entry, channel: int) {
	switch channel {
	case 0:
		slice.sort_by(entries, proc(a, b: Color_Entry) -> bool {return a.rgb[0] < b.rgb[0]})
	case 1:
		slice.sort_by(entries, proc(a, b: Color_Entry) -> bool {return a.rgb[1] < b.rgb[1]})
	case:
		slice.sort_by(entries, proc(a, b: Color_Entry) -> bool {return a.rgb[2] < b.rgb[2]})
	}
}

// Every colour observed in pass one has an exact slot, so this never has to
// search for a nearest neighbour.
quantizer_index :: #force_inline proc(q: ^Quantizer, color: image.RGB_Pixel) -> u8 {
	return q.lookup[color_key(color)]
}

Gif_Hash_Capacity :: 8192
Gif_Hash_Mask :: Gif_Hash_Capacity - 1

Gif_Lzw :: struct {
	keys:       [Gif_Hash_Capacity]u32,
	codes:      [Gif_Hash_Capacity]u16,
	bytes:      [dynamic]u8,
	bit_buffer: u32,
	bit_count:  int,
}

gif_lzw_reset :: proc(lzw: ^Gif_Lzw) {
	for &code in lzw.codes do code = 0
	clear(&lzw.bytes)
	lzw.bit_buffer = 0
	lzw.bit_count = 0
}

gif_lzw_emit :: proc(lzw: ^Gif_Lzw, code, width: int) {
	lzw.bit_buffer |= u32(code) << u32(lzw.bit_count)
	lzw.bit_count += width
	for lzw.bit_count >= 8 {
		append(&lzw.bytes, u8(lzw.bit_buffer & 0xff))
		lzw.bit_buffer >>= 8
		lzw.bit_count -= 8
	}
}

gif_lzw_finish :: proc(lzw: ^Gif_Lzw) {
	if lzw.bit_count > 0 do append(&lzw.bytes, u8(lzw.bit_buffer & 0xff))
	lzw.bit_buffer = 0
	lzw.bit_count = 0
}

gif_lzw_slot :: #force_inline proc(key: u32) -> int {
	return int((key * 0x9e3779b1) & u32(Gif_Hash_Mask))
}

gif_lzw_find :: proc(lzw: ^Gif_Lzw, key: u32) -> int {
	slot := gif_lzw_slot(key)
	for {
		code := lzw.codes[slot]
		if code == 0 do return -1
		if lzw.keys[slot] == key do return int(code) - 1
		slot = (slot + 1) & Gif_Hash_Mask
	}
}

gif_lzw_insert :: proc(lzw: ^Gif_Lzw, key: u32, code: int) {
	slot := gif_lzw_slot(key)
	for {
		if lzw.codes[slot] == 0 {
			lzw.keys[slot] = key
			lzw.codes[slot] = u16(code + 1)
			return
		}
		slot = (slot + 1) & Gif_Hash_Mask
	}
}

gif_lzw_encode :: proc(lzw: ^Gif_Lzw, pixels: []u8) -> []u8 {
	assert(len(pixels) > 0)
	gif_lzw_reset(lzw)
	clear_code, end_code := 256, 257
	next_code, code_width := 258, 9
	gif_lzw_emit(lzw, clear_code, code_width)
	prefix := int(pixels[0])
	for suffix in pixels[1:] {
		key := u32(prefix) << 8 | u32(suffix)
		if code := gif_lzw_find(lzw, key); code >= 0 {
			prefix = code
			continue
		}
		gif_lzw_emit(lzw, prefix, code_width)
		if next_code < 4096 {
			gif_lzw_insert(lzw, key, next_code)
			next_code += 1
			// The decoder adds the entry after it reads `prefix`; its next code
			// therefore grows one emission later than this encoder's next slot.
			if next_code == int(u32(1) << u32(code_width)) + 1 && code_width < 12 do code_width += 1
		} else {
			gif_lzw_emit(lzw, clear_code, code_width)
			for &code in lzw.codes do code = 0
			next_code, code_width = 258, 9
		}
		prefix = int(suffix)
	}
	gif_lzw_emit(lzw, prefix, code_width)
	// Reading the final data code still grows the decoder dictionary before it
	// consumes the end code, so keep its code width in lockstep here too.
	if next_code < 4096 {
		next_code += 1
		if next_code == int(u32(1) << u32(code_width)) + 1 && code_width < 12 do code_width += 1
	}
	gif_lzw_emit(lzw, end_code, code_width)
	gif_lzw_finish(lzw)
	return lzw.bytes[:]
}

gif_append_u16 :: #force_inline proc(out: ^[dynamic]u8, value: int) {
	append(out, u8(value), u8(value >> 8))
}

gif_append_data :: proc(out: ^[dynamic]u8, data: []u8) {
	for offset := 0; offset < len(data); {
		count := min(255, len(data) - offset)
		append(out, u8(count))
		append(out, ..data[offset:offset + count])
		offset += count
	}
	append(out, 0)
}

gif_begin :: proc(out: ^[dynamic]u8, width, height: int, palette: Palette) {
	append(out, 'G', 'I', 'F', '8', '9', 'a')
	gif_append_u16(out, width)
	gif_append_u16(out, height)
	append(out, 0xf7, Palette_Background, 0) // 256-entry global palette, background index, aspect
	for color in palette do append(out, color[0], color[1], color[2])
	append(out, 0x21, 0xff, 0x0b)
	append(out, 'N', 'E', 'T', 'S', 'C', 'A', 'P', 'E', '2', '.', '0')
	append(out, 0x03, 0x01, 0, 0, 0) // repeat forever
}

Gif_Rect :: struct {
	x, y, width, height: int,
}

// Frames after the first carry only the pixels that changed: the bounding box
// narrows the image descriptor, and transparency drops the untouched pixels
// inside it. The engine already knows which cells are dirty, so paying for a
// full-canvas image block every frame would waste what the renderer computed.
gif_append_frame :: proc(
	out: ^[dynamic]u8,
	lzw: ^Gif_Lzw,
	scratch: ^[dynamic]u8,
	current, previous: []u8,
	width: int,
	rect: Gif_Rect,
	delay: int,
	transparent: bool,
) {
	packed: u8 = 0x04 // disposal method 1: leave the frame in place
	if transparent do packed |= 0x01
	append(out, 0x21, 0xf9, 0x04, packed)
	gif_append_u16(out, delay)
	append(out, Palette_Transparent, 0)

	append(out, 0x2c)
	gif_append_u16(out, rect.x)
	gif_append_u16(out, rect.y)
	gif_append_u16(out, rect.width)
	gif_append_u16(out, rect.height)
	append(out, 0, 8) // no local palette, not interlaced, then LZW minimum code size

	clear(scratch)
	for row in rect.y ..< rect.y + rect.height {
		for column in rect.x ..< rect.x + rect.width {
			index := row * width + column
			pixel := current[index]
			if transparent && previous != nil && pixel == previous[index] {
				pixel = Palette_Transparent
			}
			append(scratch, pixel)
		}
	}
	gif_append_data(out, gif_lzw_encode(lzw, scratch[:]))
}

// Bounding box of what changed. A frame that changes nothing still has to carry
// its delay, so it degenerates to a single transparent pixel.
gif_dirty_rect :: proc(current, previous: []u8, width, height: int) -> Gif_Rect {
	left, top, right, bottom := width, height, -1, -1
	for row in 0 ..< height {
		base := row * width
		for column in 0 ..< width {
			if current[base + column] == previous[base + column] do continue
			left = min(left, column)
			right = max(right, column)
			top = min(top, row)
			bottom = max(bottom, row)
		}
	}
	if right < 0 do return {0, 0, 1, 1}
	return {left, top, right - left + 1, bottom - top + 1}
}
