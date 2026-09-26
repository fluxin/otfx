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
	for id in e.particle_sets.input do engine.set_particle(&e, id, visible = true, visual = code)
	engine.frame_build(&e)
	testing.expect_value(t, string(engine.frame_bytes(&e)), input)
	// Sparse output needs the full distance, including values beyond u16.
	last := e.particle_sets.input[len(e.particle_sets.input) - 1]
	engine.set_symbol(&e, last, "B")
	engine.frame_build(&e)
	testing.expect_value(
		t,
		string(engine.frame_bytes(&e)[:len(input) - 1]),
		input[:len(input) - 1],
	)
	testing.expect_value(t, engine.frame_bytes(&e)[len(input) - 1], u8('B'))
	engine.frame_build(&e)
	testing.expect_value(t, engine.frame_bytes(&e)[len(input) - 1], u8('B'))
	// Symbol bytes are not limited to a rune or a fixed per-cell byte capacity.
	large := strings.repeat("x", 65537 * 65)
	engine.set_symbol(&e, e.particle_sets.input[0], large)
	engine.set_symbol(&e, e.particle_sets.input[1], "C")
	engine.frame_build(&e)
	testing.expect_value(t, len(engine.frame_bytes(&e)), len(large) + len(input) - 1)
	testing.expect_value(t, string(engine.frame_bytes(&e)[:len(large)]), large)
	testing.expect_value(t, engine.frame_bytes(&e)[len(large)], u8('C'))
}
