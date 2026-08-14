package main

import common "../common"

import "../../src/effects"
import "../../src/engine"

import "core:fmt"
import "core:image"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:unicode/utf8"

// Terminal-cell captures, not ANSI parses: the tool steps the real effect and
// renderer pipeline and rasterizes the resulting cell grid.
//
// Geometry, seed and framing match the upstream ttfx gallery so the two sets of
// previews are comparable side by side -- same 81x10 Omarchy logo on an 84x13
// canvas, same centred anchors, same 7x13 cells.
Preview_Width :: 84
Preview_Height :: 13
Preview_Seed :: u64(3)

Cell_Width :: 7
Cell_Height :: 13
Gif_Hold_Centiseconds :: 150 // the finished logo rests before the loop restarts

// Playback has to run at the rate the effect actually animates at, so the frame
// delay is derived from the sampling stride rather than fixed: a fixed delay
// makes a densely sampled effect crawl and a sparsely sampled one race.
//
// GIF delays are whole centiseconds, and 100/60 is not one, so the stride is
// kept a multiple of three. Three source frames are then exactly 5 cs, and the
// preview plays back at 20 fps in real time no matter how long the effect runs.
Source_Frames_Per_Sample :: 3
Gif_Delay_Per_Sample :: Source_Frames_Per_Sample * 100 / engine.Virtual_Frame_Rate

// Above this the previews stop being cheap to load in a README, so frames are
// sampled evenly instead. The final frame is always kept.
Max_Frames :: 360

// Backstop only. matrix and thunderstorm budget a phase in seconds, and the
// previews run unpaced; the virtual clock is what keeps those bounded, so
// reaching this cap means an effect stopped converging.
Max_Simulation_Frames :: 20_000

// Demo-only arguments, matching what the upstream gallery overrides. At the
// default 0.1 only a tenth of the logo is ever misplaced, which reads as noise
// rather than as the effect; a pair consumes two characters, so 0.5 swaps all
// of them. This changes the preview, not the effect's defaults.
demo_args :: proc(kind: effects.Effect_Kind) -> []string {
	@(static) error_pairs := []string{"--error-pairs", "0.5"}
	#partial switch kind {
	case .Errorcorrect:
		return error_pairs
	}
	return nil
}

Background :: image.RGB_Pixel{0x12, 0x12, 0x1a}
Foreground :: image.RGB_Pixel{0xc8, 0xc8, 0xd0}

Logo_Env :: "OTFX_DOCS_TEXT_FILE"
Logo_Path :: "/.local/share/omarchy/logo.txt"

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
		if row < 0 || row >= r.height do continue
		for column in x ..< x + width {
			if column < 0 || column >= r.width do continue
			r.pixels[row * r.width + column] = color
		}
	}
}

color_pixel :: #force_inline proc(color: engine.Color) -> image.RGB_Pixel {
	return {color.r, color.g, color.b}
}

blend :: #force_inline proc(
	fg, bg: image.RGB_Pixel,
	alpha: u8,
) -> image.RGB_Pixel {
	if alpha == 255 do return fg
	if alpha == 0 do return bg
	a := u32(alpha)
	inverse := 255 - a
	return {
		u8((u32(fg[0]) * a + u32(bg[0]) * inverse) / 255),
		u8((u32(fg[1]) * a + u32(bg[1]) * inverse) / 255),
		u8((u32(fg[2]) * a + u32(bg[2]) * inverse) / 255),
	}
}

// Shapes carry cell-local pixels, so they reach the cell edge exactly and
// neighbouring cells join with no seam or overlap.
raster_shape :: proc(
	r: ^Raster,
	column, screen_row: int,
	shape: Cell_Shape,
	fg, bg: image.RGB_Pixel,
) {
	color := blend(fg, bg, shape.density)
	origin_x := column * Cell_Width
	origin_y := screen_row * Cell_Height

	if shape.diagonal != 0 {
		for step in 0 ..< Cell_Height {
			x := step * Cell_Width / Cell_Height
			if shape.diagonal & 1 != 0 {
				raster_fill_rect(r, origin_x + Cell_Width - 1 - x, origin_y + step, 1, 1, color)
			}
			if shape.diagonal & 2 != 0 {
				raster_fill_rect(r, origin_x + x, origin_y + step, 1, 1, color)
			}
		}
		return
	}

	rects := shape.rects
	for rect in rects[:shape.count] {
		width, height := rect.x1 - rect.x0, rect.y1 - rect.y0
		if shape.dash < 2 {
			raster_fill_rect(r, origin_x + rect.x0, origin_y + rect.y0, width, height, color)
			continue
		}
		// Dashed rules keep the run's thickness and break along its long axis.
		runs := int(shape.dash)
		if width >= height {
			for run in 0 ..< runs {
				start := run * width / runs
				stop := max(start + 1, (run * 2 + 1) * width / (runs * 2))
				raster_fill_rect(
					r,
					origin_x + rect.x0 + start,
					origin_y + rect.y0,
					stop - start,
					height,
					color,
				)
			}
		} else {
			for run in 0 ..< runs {
				start := run * height / runs
				stop := max(start + 1, (run * 2 + 1) * height / (runs * 2))
				raster_fill_rect(
					r,
					origin_x + rect.x0,
					origin_y + rect.y0 + start,
					width,
					stop - start,
					color,
				)
			}
		}
	}
}

raster_glyph :: proc(
	r: ^Raster,
	chain: ^Font_Chain,
	column, screen_row: int,
	ch: rune,
	fg, bg: image.RGB_Pixel,
) {
	glyph, ok := font_glyph(chain, ch)
	if !ok do return
	origin_x := column * Cell_Width + glyph.left
	origin_y := screen_row * Cell_Height + glyph.top
	for row in 0 ..< glyph.height {
		y := origin_y + row
		if y < 0 || y >= r.height do continue
		for pixel in 0 ..< glyph.width {
			x := origin_x + pixel
			if x < 0 || x >= r.width do continue
			alpha := glyph.coverage[row * glyph.width + pixel]
			if alpha == 0 do continue
			target := &r.pixels[y * r.width + x]
			target^ = blend(fg, target^, alpha)
		}
	}
}

raster_render_cells :: proc(
	r: ^Raster,
	chain: ^Font_Chain,
	e: ^engine.Engine,
	width, height: int,
) {
	raster_fill(r, Background)
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
			cell_background := Background
			if bg, ok := visual.bg.?; ok {
				cell_background = color_pixel(bg)
				raster_fill_rect(
					r,
					column * Cell_Width,
					screen_row * Cell_Height,
					Cell_Width,
					Cell_Height,
					cell_background,
				)
			}
			if visual.symbol == "" do continue
			fg := Foreground
			if color, ok := visual.fg.?; ok do fg = color_pixel(color)
			ch, _ := utf8.decode_rune(visual.symbol)
			if shape, is_shape := block_for(ch); is_shape {
				raster_shape(r, column, screen_row, shape, fg, cell_background)
			} else if shape, is_shape := box_for(ch); is_shape {
				raster_shape(r, column, screen_row, shape, fg, cell_background)
			} else {
				raster_glyph(r, chain, column, screen_row, ch, fg, cell_background)
			}
		}
	}
}

// Both passes rebuild from the same seed, so the second walk reproduces the
// first frame for frame. That is what lets pass one measure colours without
// holding every frame in memory.
preview_start :: proc(
	kind: effects.Effect_Kind,
	text: string,
) -> (
	run: common.Run,
	ok: bool,
) {
	cfg := engine.config_default()
	cfg.frame_rate = 0
	cfg.canvas_width = Preview_Width
	cfg.canvas_height = Preview_Height
	cfg.anchor_canvas = .C
	cfg.anchor_text = .C
	cfg.ignore_terminal_dimensions = true
	// Unpaced capture, so the seconds-budgeted effects have to advance on
	// logical frames or their length would depend on how fast this host runs.
	cfg.virtual_clock = true
	cfg.terminal_background_color = {Background[0], Background[1], Background[2]}

	run, ok = common.run_make(kind, demo_args(kind), cfg, text, Preview_Seed)
	if !ok do fmt.eprintfln("failed to build the %s preview", effect_name(kind, context.temp_allocator))
	return run, ok
}

preview_step :: proc(run: ^common.Run) -> (width, height: int, ok: bool) {
	return common.run_step(run)
}

effect_name :: common.effect_name

// Effects run to completion rather than to a hand-tuned frame window: a fixed
// last_frame per effect has to be retuned whenever effect timing shifts, and it
// cannot know where an effect naturally settles.
preview_frame_count :: proc(kind: effects.Effect_Kind, text: string) -> (int, bool) {
	run, ok := preview_start(kind, text)
	if !ok do return 0, false
	frames := 0
	for frames < Max_Simulation_Frames {
		_, _, produced := preview_step(&run)
		if !produced do break
		frames += 1
		free_all(context.temp_allocator)
	}
	return frames, frames > 0
}

gif_write_preview :: proc(
	kind: effects.Effect_Kind,
	name: string,
	text: string,
	chain: ^Font_Chain,
	quantizer: ^Quantizer,
) -> bool {
	// The engine exposes no teardown, and a preview builds three of them, so the
	// whole run is bump-allocated and released in one go.
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		fmt.eprintfln("failed to create arena for %s: %v", name, err)
		return false
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	total, ok := preview_frame_count(kind, text)
	if !ok {
		fmt.eprintfln("%s produced no frames", name)
		return false
	}
	// Stride stays a multiple of the sample size so the per-frame delay below
	// remains a whole number of centiseconds.
	stride := Source_Frames_Per_Sample
	for (total + stride - 1) / stride > Max_Frames do stride += Source_Frames_Per_Sample
	delay := stride / Source_Frames_Per_Sample * Gif_Delay_Per_Sample

	image_width := Preview_Width * Cell_Width
	image_height := Preview_Height * Cell_Height
	raster := raster_make(image_width, image_height)
	quantizer_reset(quantizer)

	// Pass one: observe every colour the sampled frames actually contain.
	{
		run, run_ok := preview_start(kind, text)
		if !run_ok do return false
		for frame in 0 ..< total {
			width, height, produced := preview_step(&run)
			if !produced do break
			if frame % stride == 0 || frame == total - 1 {
				raster_render_cells(&raster, chain, &run.engine_state, width, height)
				quantizer_observe(quantizer, raster.pixels[:])
			}
			free_all(context.temp_allocator)
		}
	}
	quantizer_build(quantizer, Background)

	// Pass two: replay and encode against the palette pass one produced.
	current := make([]u8, image_width * image_height)
	previous := make([]u8, image_width * image_height)

	gif: [dynamic]u8
	reserve(&gif, image_width * image_height)
	gif_begin(&gif, image_width, image_height, quantizer.palette)
	lzw: Gif_Lzw
	scratch: [dynamic]u8

	emitted := 0
	{
		run, run_ok := preview_start(kind, text)
		if !run_ok do return false
		for frame in 0 ..< total {
			width, height, produced := preview_step(&run)
			if !produced do break
			if frame % stride != 0 && frame != total - 1 {
				free_all(context.temp_allocator)
				continue
			}
			raster_render_cells(&raster, chain, &run.engine_state, width, height)
			for pixel, i in raster.pixels do current[i] = quantizer_index(quantizer, pixel)

			last := frame == total - 1
			frame_delay := Gif_Hold_Centiseconds if last else delay
			if emitted == 0 {
				gif_append_frame(
					&gif,
					&lzw,
					&scratch,
					current,
					nil,
					image_width,
					{0, 0, image_width, image_height},
					frame_delay,
					false,
				)
			} else {
				rect := gif_dirty_rect(current, previous, image_width, image_height)
				gif_append_frame(
					&gif,
					&lzw,
					&scratch,
					current,
					previous,
					image_width,
					rect,
					frame_delay,
					true,
				)
			}
			copy(previous, current)
			emitted += 1
			free_all(context.temp_allocator)
		}
	}
	append(&gif, 0x3b)

	path := fmt.tprintf("docs/images/%s.gif", name)
	if err := os.write_entire_file(path, gif[:]); err != nil {
		fmt.eprintfln("failed to write %s: %v", path, err)
		return false
	}
	note := "" if stride == 1 else fmt.tprintf(", sampled 1 in %d", stride)
	fmt.printfln(
		"%-16s %3d frames of %3d%s, %d colors, %d KB",
		name,
		emitted,
		total,
		note,
		len(quantizer.observed),
		len(gif) / 1024,
	)
	return true
}

// Upstream reads the same file through TTFX_DEMO_TEXT_FILE. Reading it rather
// than committing a copy keeps someone else's logo out of the repository.
load_text :: proc() -> (string, bool) {
	path := os.get_env(Logo_Env, context.allocator)
	if path == "" {
		home := os.get_env("HOME", context.allocator)
		defer delete(home)
		path = strings.concatenate({home, Logo_Path}, context.allocator)
	}
	defer delete(path)
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("could not read preview text: %s (%v)", path, err)
		fmt.eprintfln("set %s to override the path", Logo_Env)
		return "", false
	}
	return strings.trim_right(string(data), "\n"), true
}

main :: proc() {
	if err := os.make_directory_all("docs/images"); err != nil && err != .Exist {
		fmt.eprintfln("failed to create docs/images: %v", err)
		os.exit(1)
	}
	text, text_ok := load_text()
	if !text_ok do os.exit(1)

	chain: Font_Chain
	if !font_chain_load(&chain) do os.exit(1)
	defer font_chain_destroy(&chain)

	quantizer := quantizer_make()
	defer quantizer_destroy(&quantizer)

	// Optional effect names restrict the run, so a single preview can be
	// re-rendered while iterating instead of rebuilding the whole gallery.
	selected := os.args[1:]
	for kind in effects.Effect_Kind {
		name := effect_name(kind)
		wanted := len(selected) == 0
		for argument in selected do wanted |= argument == name
		if !wanted {
			delete(name)
			continue
		}
		if !gif_write_preview(kind, name, text, &chain, &quantizer) do os.exit(1)
		delete(name)
		free_all(context.temp_allocator)
	}
}
