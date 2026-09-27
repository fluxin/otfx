package regression

import "../src/engine"
import "core:container/bit_array"
import "core:mem"
import "core:testing"

@(test)
dirty_bits_keep_fixed_lengths_across_word_boundaries :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	for width in ([3]int{1, 64, 65}) {
		cfg := engine.config_default()
		cfg.ignore_terminal_dimensions = true
		cfg.canvas_width, cfg.canvas_height = width, 2
		e, err := engine.engine_make("A", cfg)
		testing.expect_value(t, err, engine.Input_Error.None)
		engine.frame_build(&e) // Drain the initial full paint before testing mutations.
		id := e.particle_sets.input[0]
		corner := width + width - 1 // second top-down row, last column
		engine.set_placement(&e, id, {width, 1}, true, 0)
		engine.frame_build(&e)
		testing.expect_value(t, bit_array.len(&e.dirty_cells), width * 2)
		testing.expect_value(t, bit_array.len(&e.emit_cells), width * 2)
		testing.expect(t, bit_array.get(&e.emit_cells, corner))
		testing.expect_value(t, e.slots[corner][0], u8('A'))
		engine.set_position(&e, id, {width + 1, 1}) // Clipped departure dirties the old cell.
		engine.frame_build(&e)
		testing.expect(t, bit_array.get(&e.emit_cells, corner))
		testing.expect_value(t, e.slots[corner][0], u8(' '))
		engine.frame_build(&e)
		testing.expect(t, !bit_array.get(&e.emit_cells, corner))
		testing.expect_value(t, bit_array.len(&e.emit_cells), width * 2)
	}
}
