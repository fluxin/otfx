package regression

import "../src/engine"
import "core:mem"
import "core:strings"
import "core:testing"

@(test)
wide_raster_preserves_cursor_distances_and_long_symbols :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 65537, 1
	cfg.ignore_terminal_dimensions = true
	input := strings.repeat("A", cfg.canvas_width)
	e, err := engine.engine_make(input, cfg, context.allocator)
	testing.expect_value(t, err, engine.Input_Error.None)
	code := engine.prepare_visual(&e, {symbol = "A"})
	for id in e.character_sets.input do engine.set_character(&e, id, visible = true, visual = code)
	engine.frame_build_all(&e)
	testing.expect_value(t, string(e.out_buf[:]), input)
	// Sparse output needs the full distance, including values beyond u16.
	last := e.character_sets.input[len(e.character_sets.input) - 1]
	engine.set_symbol(&e, last, "B")
	engine.frame_build_all(&e)
	testing.expect_value(t, string(e.out_buf[:]), "\x1b[65536CB")
	engine.frame_build_all(&e)
	testing.expect_value(t, len(e.out_buf), 0)
	// Symbol bytes are not limited to a rune or a fixed per-cell byte capacity.
	large := strings.repeat("x", 65537 * 65)
	engine.set_symbol(&e, e.character_sets.input[0], large)
	engine.set_symbol(&e, e.character_sets.input[1], "C")
	engine.frame_build_all(&e)
	testing.expect_value(t, len(e.out_buf), len(large) + 1)
	testing.expect_value(t, string(e.out_buf[:len(large)]), large)
	testing.expect_value(t, e.out_buf[len(large)], u8('C'))
}
