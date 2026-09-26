package regression

import "../src/engine"
import "core:mem"
import "core:strings"
import "core:testing"

@(test)
wide_raster_preserves_cursor_distances_and_utf8_symbols :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 65537, 1
	cfg.ignore_terminal_dimensions = true
	input := strings.repeat("A", cfg.canvas_width)
	e, err := engine.engine_make(input, cfg)
	testing.expect_value(t, err, engine.Input_Error.None)
	code := engine.prepare_appearance(&e, engine.Appearance{})
	for id in e.particle_sets.input {
		engine.set_particle(&e, id, engine.Visible(true))
		engine.set_appearance(&e, id, code)
	}
	engine.frame_build(&e)
	testing.expect_value(t, string(frame_without_padding(&e)), input)
	// Sparse output needs the full distance, including values beyond u16.
	last := e.particle_sets.input[len(e.particle_sets.input) - 1]
	engine.set_symbol(&e, last, 'B')
	engine.frame_build(&e)
	testing.expect_value(
		t,
		string(frame_without_padding(&e)[:len(input) - 1]),
		input[:len(input) - 1],
	)
	testing.expect_value(t, frame_without_padding(&e)[len(input) - 1], u8('B'))
	engine.frame_build(&e)
	testing.expect_value(t, len(frame_without_padding(&e)), 0)
	// Four UTF-8 bytes fit the same slot without moving the next cell.
	engine.set_symbol(&e, e.particle_sets.input[0], '𐍈')
	engine.set_symbol(&e, e.particle_sets.input[1], 'C')
	engine.frame_build(&e)
	bytes := frame_without_padding(&e)
	testing.expect_value(t, len(bytes), len(input) + 3)
	testing.expect_value(t, string(bytes[:4]), "𐍈")
	testing.expect_value(t, bytes[4], u8('C'))
}
