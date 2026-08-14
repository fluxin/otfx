package main

import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import stbtt "vendor:stb/truetype"

// Cell glyphs come from two sources. Block elements are filled as exact cell
// rectangles, because a rasterized outline lands on fractional pixel boundaries
// at these cell sizes and puts seams through solid areas -- the Omarchy logo is
// nothing but U+2580..U+259F, so that path has to be exact. Everything else is
// rasterized from a vendored font chain.
//
// The chain is explicit rather than inherited from fontconfig: ttfx renders SVG
// through rsvg and silently picks up whatever the host has installed, which is
// why its matrix.gif needs a system CJK font to avoid tofu. Pinning the three
// faces here makes the previews reproducible on any machine.
Font_Paths :: [3]string {
	"third_party/fonts/JetBrainsMono-Regular.ttf",
	"third_party/fonts/DejaVuSansMono-latinext.ttf",
	"third_party/fonts/NotoSansMonoCJKjp-katakana.otf",
}

Font_Face :: struct {
	info:  stbtt.fontinfo,
	data:  []u8,
	scale: f32,
}

Glyph :: struct {
	coverage:   []u8, // 8-bit alpha, width * height
	width:      int,
	height:     int,
	left, top:  int, // pixel offset from the cell origin
}

Font_Chain :: struct {
	faces:     [len(Font_Paths)]Font_Face,
	count:     int,
	baseline:  int,
	cache:     map[rune]Glyph,
	// The cache outlives the per-preview arena, so it keeps its own allocator
	// rather than inheriting whichever one happens to be installed at the point
	// a rune is first rasterized.
	allocator: mem.Allocator,
}

font_chain_load :: proc(chain: ^Font_Chain) -> bool {
	chain.allocator = context.allocator
	chain.cache = make(map[rune]Glyph, 0, chain.allocator)
	for path in Font_Paths {
		data, err := os.read_entire_file(path, chain.allocator)
		if err != nil {
			fmt.eprintfln("missing vendored font: %s (%v)", path, err)
			fmt.eprintln("run tools/setup/vendor_fonts.sh first")
			return false
		}
		face := &chain.faces[chain.count]
		face.data = data
		offset := stbtt.GetFontOffsetForIndex(raw_data(data), 0)
		if !stbtt.InitFont(&face.info, raw_data(data), offset) {
			fmt.eprintfln("failed to parse font: %s", path)
			return false
		}

		// Monospace advance sets the horizontal scale so a glyph fills its cell,
		// but a face whose ascent-to-descent span is taller than the cell would
		// then overflow into its neighbours, so the smaller scale wins.
		advance, lsb: c.int
		stbtt.GetCodepointHMetrics(&face.info, 'M', &advance, &lsb)
		ascent, descent, line_gap: c.int
		stbtt.GetFontVMetrics(&face.info, &ascent, &descent, &line_gap)
		width_scale := f32(Cell_Width) / f32(advance)
		height_scale := f32(Cell_Height) / f32(ascent - descent)
		face.scale = min(width_scale, height_scale)

		if chain.count == 0 {
			span := f32(ascent - descent) * face.scale
			chain.baseline = int(
				(f32(Cell_Height) - span) / 2 + f32(ascent) * face.scale + 0.5,
			)
		}
		chain.count += 1
	}
	return chain.count > 0
}

font_chain_destroy :: proc(chain: ^Font_Chain) {
	for _, glyph in chain.cache do delete(glyph.coverage, chain.allocator)
	delete(chain.cache)
	for i in 0 ..< chain.count do delete(chain.faces[i].data, chain.allocator)
}

// First face that actually has an outline for the rune. stb reports glyph 0 for
// a missing codepoint, which is the .notdef box -- skipping it is what keeps the
// katakana in matrix from rendering as tofu.
font_chain_face :: proc(chain: ^Font_Chain, ch: rune) -> ^Font_Face {
	for i in 0 ..< chain.count {
		face := &chain.faces[i]
		if stbtt.FindGlyphIndex(&face.info, ch) != 0 do return face
	}
	return nil
}

font_glyph :: proc(chain: ^Font_Chain, ch: rune) -> (Glyph, bool) {
	if cached, ok := chain.cache[ch]; ok do return cached, cached.coverage != nil

	glyph: Glyph
	if face := font_chain_face(chain, ch); face != nil {
		width, height, xoff, yoff: c.int
		bitmap := stbtt.GetCodepointBitmap(
			&face.info,
			face.scale,
			face.scale,
			ch,
			&width,
			&height,
			&xoff,
			&yoff,
		)
		if bitmap != nil {
			glyph.width = int(width)
			glyph.height = int(height)
			glyph.coverage = make([]u8, glyph.width * glyph.height, chain.allocator)
			copy(glyph.coverage, bitmap[:glyph.width * glyph.height])
			stbtt.FreeBitmap(bitmap, nil)

			// Horizontally centre what the rasterizer produced rather than
			// trusting the side bearing: the fallback faces are not metrically
			// compatible with the primary, and off-centre glyphs would drift
			// out of their columns exactly like ttfx's substituted CJK does.
			glyph.left = (Cell_Width - glyph.width) / 2
			glyph.top = chain.baseline + int(yoff)
		}
	}
	chain.cache[ch] = glyph
	return glyph, glyph.coverage != nil
}

// A filled cell shape in cell-local pixels. Blocks and box drawing both render
// through this so there is one rectangle path, not two.
Cell_Rect :: struct {
	x0, y0, x1, y1: int, // x1/y1 exclusive
}

Cell_Shape :: struct {
	rects:    [8]Cell_Rect,
	count:    int,
	density:  u8, // 255 unless the glyph is a shade
	dash:     u8, // split each rect into this many runs along its long axis
	diagonal: u8, // 1 '/', 2 '\', 3 both
}

// Block elements are specified in eighths of the cell and resolved to pixels
// here, so a full block covers its cell exactly and neighbours leave no seam.
block_for :: proc(ch: rune) -> (Cell_Shape, bool) {
	eighth_x :: proc(n: int) -> int {return n * Cell_Width / 8}
	eighth_y :: proc(n: int) -> int {return n * Cell_Height / 8}

	solid :: proc(x0, y0, x1, y1: int) -> (Cell_Shape, bool) {
		return {
				rects = {
					0 = {eighth_x(x0), eighth_y(y0), eighth_x(x1), eighth_y(y1)},
				},
				count = 1,
				density = 255,
			},
			true
	}
	pair :: proc(a, b: Cell_Rect) -> (Cell_Shape, bool) {
		return {
				rects = {
					0 = {eighth_x(a.x0), eighth_y(a.y0), eighth_x(a.x1), eighth_y(a.y1)},
					1 = {eighth_x(b.x0), eighth_y(b.y0), eighth_x(b.x1), eighth_y(b.y1)},
				},
				count = 2,
				density = 255,
			},
			true
	}
	shade :: proc(density: u8) -> (Cell_Shape, bool) {
		return {rects = {0 = {0, 0, Cell_Width, Cell_Height}}, count = 1, density = density},
			true
	}

	switch ch {
	// Lower blocks, one eighth at a time.
	case '▁':
		return solid(0, 7, 8, 8)
	case '▂':
		return solid(0, 6, 8, 8)
	case '▃':
		return solid(0, 5, 8, 8)
	case '▄':
		return solid(0, 4, 8, 8)
	case '▅':
		return solid(0, 3, 8, 8)
	case '▆':
		return solid(0, 2, 8, 8)
	case '▇':
		return solid(0, 1, 8, 8)
	case '█':
		return solid(0, 0, 8, 8)
	// Left blocks.
	case '▉':
		return solid(0, 0, 7, 8)
	case '▊':
		return solid(0, 0, 6, 8)
	case '▋':
		return solid(0, 0, 5, 8)
	case '▌':
		return solid(0, 0, 4, 8)
	case '▍':
		return solid(0, 0, 3, 8)
	case '▎':
		return solid(0, 0, 2, 8)
	case '▏':
		return solid(0, 0, 1, 8)
	case '▐':
		return solid(4, 0, 8, 8)
	case '▀':
		return solid(0, 0, 8, 4)
	case '▔':
		return solid(0, 0, 8, 1)
	case '▕':
		return solid(7, 0, 8, 8)
	// Shades blend towards the background instead of dithering, which keeps
	// large filled regions flat rather than stippled.
	case '░':
		return shade(64)
	case '▒':
		return shade(128)
	case '▓':
		return shade(191)
	// Quadrants.
	case '▖':
		return solid(0, 4, 4, 8)
	case '▗':
		return solid(4, 4, 8, 8)
	case '▘':
		return solid(0, 0, 4, 4)
	case '▝':
		return solid(4, 0, 8, 4)
	case '▙':
		return pair({0, 0, 4, 8}, {4, 4, 8, 8})
	case '▛':
		return pair({0, 0, 8, 4}, {0, 4, 4, 8})
	case '▜':
		return pair({0, 0, 8, 4}, {4, 4, 8, 8})
	case '▟':
		return pair({0, 4, 8, 8}, {4, 0, 8, 4})
	case '▚':
		return pair({0, 0, 4, 4}, {4, 4, 8, 8})
	case '▞':
		return pair({4, 0, 8, 4}, {0, 4, 4, 8})
	}
	return {}, false
}
