package main

import "../../src/effects"
import "../../src/engine"

import "core:fmt"
import "core:image"
import "core:math/rand"
import "core:os"
import "core:unicode/utf8"

// The generated GIFs are terminal-cell captures, not ANSI parses. They use
// the active Omarchy Tokyo Night colors and the current 9-point JetBrains Mono
// cell geometry (8x18 with Ghostty's 14-pixel padding).
Preview :: struct {
	name:         string,
	kind:         effects.Effect_Kind,
	last_frame:   int,
	frame_stride: int,
}

Preview_Input :: "otfx\nOdin terminal effects"
Preview_Width :: 64
Preview_Height :: 16
Preview_Seed :: u64(1)

Omarchy_Background :: engine.Color{0x1a, 0x1b, 0x26}
Omarchy_Foreground :: engine.Color{0xa9, 0xb1, 0xd6}
Omarchy_Ansi :: [16]engine.Color {
	{0x32, 0x34, 0x4a},
	{0xf7, 0x76, 0x8e},
	{0x9e, 0xce, 0x6a},
	{0xe0, 0xaf, 0x68},
	{0x7a, 0xa2, 0xf7},
	{0xad, 0x8e, 0xe6},
	{0x44, 0x9d, 0xab},
	{0x78, 0x7c, 0x99},
	{0x44, 0x4b, 0x6a},
	{0xff, 0x7a, 0x93},
	{0xb9, 0xf2, 0x7c},
	{0xff, 0x9e, 0x64},
	{0x7d, 0xa6, 0xff},
	{0xbb, 0x9a, 0xf7},
	{0x0d, 0xb9, 0xd7},
	{0xac, 0xb0, 0xd0},
}

Cell_Width :: 8
Cell_Height :: 18
Cell_Padding :: 14
Gif_Delay_Centiseconds :: 8

Previews :: [3]Preview {
	{name = "decrypt", kind = .Decrypt, last_frame = 170, frame_stride = 2},
	{name = "fireworks", kind = .Fireworks, last_frame = 360, frame_stride = 4},
	{name = "blackhole", kind = .Blackhole, last_frame = 360, frame_stride = 4},
}

Raster :: struct {
	width, height: int,
	pixels:        [dynamic]image.RGB_Pixel,
}

raster_make :: proc(width, height: int) -> Raster {
	return {width, height, make([dynamic]image.RGB_Pixel, width * height)}
}

raster_fill :: proc(r: ^Raster, color: image.RGB_Pixel) {
	for &pixel in r.pixels do pixel = color
}

raster_fill_rect :: proc(r: ^Raster, x, y, width, height: int, color: image.RGB_Pixel) {
	for row in y ..< y + height {
		for column in x ..< x + width do r.pixels[row * r.width + column] = color
	}
}

color_pixel :: #force_inline proc(color: engine.Color) -> image.RGB_Pixel {
	return {color.r, color.g, color.b}
}

glyph_unknown :: proc(ch: rune) -> [7]u8 {
	rows: [7]u8
	bits := u32(ch) * 0x45d9f3b
	for row in 0 ..< len(rows) {
		value := u8((bits >> u32((row * 5) % 24)) & 0x1f)
		rows[row] = value if value != 0 else 0x04
	}
	return rows
}

// A compact, fixed terminal glyph set keeps the documentation renderer native
// and reproducible. Unknown printable runes retain a stable five-bit glyph so
// decryption and glitch phases remain visibly distinct.
glyph_rows :: proc(ch: rune) -> [7]u8 {
	switch ch {
	case ' ', '\u0000':
		return {}
	case 'a', 'A':
		return {0x0e, 0x11, 0x11, 0x1f, 0x11, 0x11, 0x11}
	case 'b', 'B':
		return {0x1e, 0x11, 0x11, 0x1e, 0x11, 0x11, 0x1e}
	case 'c', 'C':
		return {0x0e, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0e}
	case 'd', 'D':
		return {0x1e, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1e}
	case 'e', 'E':
		return {0x1f, 0x10, 0x10, 0x1e, 0x10, 0x10, 0x1f}
	case 'f', 'F':
		return {0x1f, 0x10, 0x10, 0x1e, 0x10, 0x10, 0x10}
	case 'g', 'G':
		return {0x0e, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0f}
	case 'h', 'H':
		return {0x11, 0x11, 0x11, 0x1f, 0x11, 0x11, 0x11}
	case 'i', 'I':
		return {0x0e, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0e}
	case 'j', 'J':
		return {0x07, 0x02, 0x02, 0x02, 0x12, 0x12, 0x0c}
	case 'k', 'K':
		return {0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11}
	case 'l', 'L':
		return {0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1f}
	case 'm', 'M':
		return {0x11, 0x1b, 0x15, 0x15, 0x11, 0x11, 0x11}
	case 'n', 'N':
		return {0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11}
	case 'o', 'O':
		return {0x0e, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0e}
	case 'p', 'P':
		return {0x1e, 0x11, 0x11, 0x1e, 0x10, 0x10, 0x10}
	case 'q', 'Q':
		return {0x0e, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0d}
	case 'r', 'R':
		return {0x1e, 0x11, 0x11, 0x1e, 0x14, 0x12, 0x11}
	case 's', 'S':
		return {0x0f, 0x10, 0x10, 0x0e, 0x01, 0x01, 0x1e}
	case 't', 'T':
		return {0x1f, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04}
	case 'u', 'U':
		return {0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0e}
	case 'v', 'V':
		return {0x11, 0x11, 0x11, 0x11, 0x11, 0x0a, 0x04}
	case 'w', 'W':
		return {0x11, 0x11, 0x11, 0x15, 0x15, 0x15, 0x0a}
	case 'x', 'X':
		return {0x11, 0x11, 0x0a, 0x04, 0x0a, 0x11, 0x11}
	case 'y', 'Y':
		return {0x11, 0x11, 0x0a, 0x04, 0x04, 0x04, 0x04}
	case 'z', 'Z':
		return {0x1f, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1f}
	case '0':
		return {0x0e, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0e}
	case '1':
		return {0x04, 0x0c, 0x04, 0x04, 0x04, 0x04, 0x0e}
	case '2':
		return {0x0e, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1f}
	case '3':
		return {0x1e, 0x01, 0x01, 0x0e, 0x01, 0x01, 0x1e}
	case '4':
		return {0x02, 0x06, 0x0a, 0x12, 0x1f, 0x02, 0x02}
	case '5':
		return {0x1f, 0x10, 0x10, 0x1e, 0x01, 0x01, 0x1e}
	case '6':
		return {0x0e, 0x10, 0x10, 0x1e, 0x11, 0x11, 0x0e}
	case '7':
		return {0x1f, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08}
	case '8':
		return {0x0e, 0x11, 0x11, 0x0e, 0x11, 0x11, 0x0e}
	case '9':
		return {0x0e, 0x11, 0x11, 0x0f, 0x01, 0x01, 0x0e}
	case '*':
		return {0x00, 0x15, 0x0e, 0x1f, 0x0e, 0x15, 0x00}
	case '▉', '█':
		return {0x1f, 0x1f, 0x1f, 0x1f, 0x1f, 0x1f, 0x1f}
	case '▓':
		return {0x15, 0x1f, 0x15, 0x1f, 0x15, 0x1f, 0x15}
	case '▒':
		return {0x15, 0x0a, 0x15, 0x0a, 0x15, 0x0a, 0x15}
	case '░':
		return {0x11, 0x00, 0x04, 0x00, 0x11, 0x00, 0x04}
	case '◉':
		return {0x0e, 0x11, 0x15, 0x1b, 0x15, 0x11, 0x0e}
	case '●':
		return {0x0e, 0x1f, 0x1f, 0x1f, 0x1f, 0x1f, 0x0e}
	case '•', '·':
		return {0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00}
	case '°':
		return {0x06, 0x09, 0x09, 0x06, 0x00, 0x00, 0x00}
	case '¤':
		return {0x00, 0x0a, 0x15, 0x11, 0x15, 0x0a, 0x00}
	}
	return glyph_unknown(ch)
}

raster_glyph :: proc(
	r: ^Raster,
	column, screen_row: int,
	symbol: string,
	color: image.RGB_Pixel,
	bold: bool,
) {
	ch, _ := utf8.decode_rune(symbol)
	rows := glyph_rows(ch)
	x0 := Cell_Padding + column * Cell_Width + 1
	y0 := Cell_Padding + screen_row * Cell_Height + 2
	for bits, row in rows {
		for bit in 0 ..< 5 {
			mask := u8(1) << u8(4 - bit)
			if bits & mask == 0 do continue
			for dy in 0 ..< 2 {
				x := x0 + bit
				y := y0 + row * 2 + dy
				r.pixels[y * r.width + x] = color
				if bold && x + 1 < Cell_Padding + (column + 1) * Cell_Width {
					r.pixels[y * r.width + x + 1] = color
				}
			}
		}
	}
}

raster_render_cells :: proc(r: ^Raster, e: ^engine.Engine, width, height: int) {
	raster_fill(r, color_pixel(Omarchy_Background))
	cells := e.render_cells[:width * height]
	visuals := e.chars.visual[:]
	input_styles := e.chars.input_style[:]
	uses_input_preexisting_colors := e.chars.uses_input_preexisting_colors[:]
	for screen_row in 0 ..< height {
		row_index := height - 1 - screen_row
		for column in 0 ..< width {
			cell := cells[row_index * width + column]
			if cell == engine.EMPTY_CELL do continue
			id := int(cell)
			visual := engine.effective_visual(
				visuals[id],
				input_styles[id],
				uses_input_preexisting_colors[id],
				e.cfg.existing_color_handling,
			)
			if bg, ok := visual.bg.?; ok {
				raster_fill_rect(
					r,
					Cell_Padding + column * Cell_Width,
					Cell_Padding + screen_row * Cell_Height,
					Cell_Width,
					Cell_Height,
					color_pixel(bg),
				)
			}
			if visual.symbol == "" do continue
			fg := Omarchy_Foreground
			if color, ok := visual.fg.?; ok do fg = color
			raster_glyph(r, column, screen_row, visual.symbol, color_pixel(fg), visual.bold)
		}
	}
}

Palette :: [256]image.RGB_Pixel

palette_make :: proc() -> Palette {
	palette: Palette
	palette[0] = color_pixel(Omarchy_Background)
	palette[1] = color_pixel(Omarchy_Foreground)
	for color, i in Omarchy_Ansi do palette[i + 2] = color_pixel(color)
	index := 18
	for red in 0 ..< 6 {
		for green in 0 ..< 6 {
			for blue in 0 ..< 6 {
				palette[index] = {u8(red * 51), u8(green * 51), u8(blue * 51)}
				index += 1
			}
		}
	}
	for index < len(palette) {
		value := u8((index - 234) * 255 / 21)
		palette[index] = {value, value, value}
		index += 1
	}
	return palette
}

palette_index :: #force_inline proc(palette: Palette, color: image.RGB_Pixel) -> u8 {
	for index in 0 ..< 18 {
		if palette[index] == color do return u8(index)
	}
	red := int(color[0]) * 5 / 255
	green := int(color[1]) * 5 / 255
	blue := int(color[2]) * 5 / 255
	return u8(18 + red * 36 + green * 6 + blue)
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
	append(out, 0xf7, 0, 0) // 256-entry global palette, background index, aspect ratio
	for color in palette do append(out, color[0], color[1], color[2])
	append(out, 0x21, 0xff, 0x0b)
	append(out, 'N', 'E', 'T', 'S', 'C', 'A', 'P', 'E', '2', '.', '0')
	append(out, 0x03, 0x01, 0, 0, 0) // repeat forever
}

gif_append_frame :: proc(out: ^[dynamic]u8, lzw: ^Gif_Lzw, pixels: []u8, width, height: int) {
	append(out, 0x21, 0xf9, 0x04, 0x04) // graphic control extension; do not dispose
	gif_append_u16(out, Gif_Delay_Centiseconds)
	append(out, 0, 0)
	append(out, 0x2c)
	gif_append_u16(out, 0)
	gif_append_u16(out, 0)
	gif_append_u16(out, width)
	gif_append_u16(out, height)
	append(out, 0, 8) // image descriptor, then LZW minimum code size
	encoded := gif_lzw_encode(lzw, pixels)
	gif_append_data(out, encoded)
}

gif_write_preview :: proc(preview: Preview) -> bool {
	cfg := engine.config_default()
	cfg.frame_rate = 0
	cfg.canvas_width = Preview_Width
	cfg.canvas_height = Preview_Height
	cfg.ignore_terminal_dimensions = true
	cfg.terminal_background_color = Omarchy_Background

	rand.reset_u64(Preview_Seed)
	e, message, engine_ok := engine.engine_make(Preview_Input, cfg, context.allocator)
	if !engine_ok {
		fmt.eprintfln("failed to build %s preview engine: %s", preview.name, message)
		return false
	}
	effect, effect_ok := effects.make_effect(preview.kind, nil)
	if !effect_ok {
		fmt.eprintfln("failed to build %s preview effect", preview.name)
		return false
	}
	effects.build_effect(&effect, &e)
	free_all(context.temp_allocator)

	image_width := 2 * Cell_Padding + Preview_Width * Cell_Width
	image_height := 2 * Cell_Padding + Preview_Height * Cell_Height
	raster := raster_make(image_width, image_height)
	defer delete(raster.pixels)
	indices := make([dynamic]u8, image_width * image_height)
	defer delete(indices)
	palette := palette_make()
	gif: [dynamic]u8
	defer delete(gif)
	reserve(&gif, image_width * image_height * 3)
	gif_begin(&gif, image_width, image_height, palette)
	lzw: Gif_Lzw
	defer delete(lzw.bytes)

	frames := 0
	for frame in 0 ..= preview.last_frame {
		render_candidates, produced := effects.next_frame(&effect, &e)
		if !produced {
			fmt.eprintfln("%s ended before source frame %d", preview.name, preview.last_frame)
			return false
		}
		width, height: int
		if render_candidates == nil {
			width, height = engine.update_render_cells_all(&e)
		} else {
			width, height = engine.update_render_cells_selected(&e, render_candidates)
		}
		if frame % preview.frame_stride == 0 {
			raster_render_cells(&raster, &e, width, height)
			for pixel, i in raster.pixels do indices[i] = palette_index(palette, pixel)
			gif_append_frame(&gif, &lzw, indices[:], image_width, image_height)
			frames += 1
		}
		free_all(context.temp_allocator)
	}
	append(&gif, 0x3b)
	path := fmt.tprintf("docs/images/%s.gif", preview.name)
	if err := os.write_entire_file(path, gif[:]); err != nil {
		fmt.eprintfln("failed to write %s: %v", path, err)
		return false
	}
	fmt.printfln("wrote %s (%d frames)", path, frames)
	return true
}

main :: proc() {
	if err := os.make_directory_all("docs/images"); err != nil && err != .Exist {
		fmt.eprintfln("failed to create docs/images: %v", err)
		os.exit(1)
	}
	for preview in Previews {
		if !gif_write_preview(preview) do os.exit(1)
	}
}
