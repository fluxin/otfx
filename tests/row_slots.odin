package regression

import "../src/engine"
import "core:mem"
import "core:strings"
import "core:testing"

@(test)
row_slots_patch_glyphs_without_shifting_neighbors :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	for no_color in ([]bool{false, true}) {
		cfg := engine.config_default()
		cfg.canvas_width, cfg.canvas_height = 3, 1
		cfg.ignore_terminal_dimensions, cfg.no_color = true, no_color
		e, err := engine.engine_make("ABC", cfg, context.allocator)
		testing.expect_value(t, err, engine.Input_Error.None)
		for id in e.particle_sets.input {
			engine.set_particle(&e, id, visible = true)
			engine.set_foreground(&e, id, engine.Color{1, 2, 3})
		}
		engine.frame_build(&e)
		stride := engine.cell_bytes(&e)
		prefix := 0 if no_color else 43
		base := &e.rows[0].bytes[0]
		left := strings.clone(string(e.rows[0].bytes[:stride]))
		right := strings.clone(string(e.rows[0].bytes[2 * stride:]))
		id := e.particle_sets.input[1]
		for symbol in ([]string{"𐍈", "█", "é", "A", "", "Z"}) {
			engine.set_symbol(&e, id, symbol)
			// Inspect the row before frame_build: the setter wrote it directly.
			glyph := e.rows[0].bytes[stride + prefix:stride + prefix + 4]
			testing.expect_value(t, string(glyph[:len(symbol)]), symbol)
			for b in glyph[len(symbol):] do testing.expect_value(t, b, u8(0))
			testing.expect_value(t, string(e.rows[0].bytes[:stride]), left)
			testing.expect_value(t, string(e.rows[0].bytes[2 * stride:]), right)
			testing.expect_value(t, e.rows[0].flags, bit_set[engine.Row_Flag]{.Appearance})
			engine.frame_build(&e)
			testing.expect_value(t, len(e.output_parts), 1)
			testing.expect_value(t, len(e.output_parts[0]), 3 * stride)
			testing.expect(t, &e.output_parts[0][0] == base)
		}
		engine.set_symbol(&e, id, "long symbol")
		engine.frame_build(&e)
		testing.expect(t, strings.contains(frame_text(&e), "long symbol"))
		engine.set_symbol(&e, id, "B")
		engine.set_foreground(&e, id, nil)
		engine.frame_build(&e)
		testing.expect_value(t, len(e.output_parts), 1)
		testing.expect_value(t, string(e.rows[0].bytes[:stride]), left)
		testing.expect_value(t, string(e.rows[0].bytes[2 * stride:]), right)
	}
}

@(test)
input_ignores_terminal_nul_padding :: proc(t: ^testing.T) {
	lines, err := engine.preprocess_input("A\x00\x00\x00█\x00B", 4)
	defer {
		for line in lines do delete(line.cells)
		delete(lines)
	}
	testing.expect_value(t, err, engine.Input_Error.None)
	testing.expect_value(t, len(lines), 1)
	testing.expect_value(t, lines[0].width, 3)
	testing.expect_value(t, lines[0].cells[0].symbol, rune('A'))
	testing.expect_value(t, lines[0].cells[1].symbol, rune('█'))
	testing.expect_value(t, lines[0].cells[2].symbol, rune('B'))
}
