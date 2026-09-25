package regression

import "../src/effects"
import "../src/engine"
import "core:math/rand"
import "core:mem"
import "core:testing"

@(test)
rebuilt_output_storage_does_not_grow :: proc(t: ^testing.T) {
	base_allocator := context.allocator
	// Rebuilding for growth and then shrink must derive a fresh reservation.
	for no_color in ([]bool{false, true}) {
		previous_capacity := 0
		for dimensions, index in ([]engine.Coord{{1, 1}, {40, 12}, {200, 50}, {7, 3}}) {
			arena: mem.Dynamic_Arena
			mem.dynamic_arena_init(&arena)
			defer mem.dynamic_arena_destroy(&arena)
			track: mem.Tracking_Allocator
			mem.tracking_allocator_init(&track, mem.dynamic_arena_allocator(&arena))
			defer mem.tracking_allocator_destroy(&track)
			context.allocator = mem.tracking_allocator(&track)
			defer context.allocator = base_allocator
			cfg := engine.config_default()
			cfg.canvas_width, cfg.canvas_height = dimensions.column, dimensions.row
			cfg.ignore_terminal_dimensions, cfg.no_color = true, no_color
			e, err := engine.engine_make("A", cfg, context.allocator)
			testing.expect(t, err == .None)
			capacity := cap(e.out_buf)
			if index > 0 do testing.expect_value(t, capacity > previous_capacity, index < 3)
			previous_capacity = capacity
			allocations := track.total_allocation_count
			// Full styled output, then sparse glyphs, erased cells, and skipped
			// rows exercise both encoded cell size and relative cursor movement.
			for pass in 0 ..< 5 {
				for id in 0 ..< len(e.chars) {
					e.chars.is_visible[id] =
						pass == 0 ||
						(pass == 1 && id % 2 == 0) ||
						(pass == 3 && e.chars.current_coord[id].row % 3 == 0) ||
						(pass == 4 && id == len(e.chars) - 1)
					e.chars.visual[id] = {
						symbol = "𐍈",
						fg     = engine.Color{255, 254, u8(pass)},
						bg     = engine.Color{253, 252, 251},
						bold   = true,
					}
				}
				engine.frame_build_all(&e)
				testing.expect_value(t, track.total_allocation_count, allocations)
				testing.expect_value(t, cap(e.out_buf), capacity)
			}
		}
	}
}

@(test)
bounded_playback_reuses_build_storage :: proc(t: ^testing.T) {
	base_allocator := context.allocator
	for kind in effects.Effect_Kind {
		// Recursive strike generation and overlapping spark pools remain dynamic.
		if kind == .Thunderstorm do continue
		arena: mem.Dynamic_Arena
		mem.dynamic_arena_init(&arena)
		defer mem.dynamic_arena_destroy(&arena)
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, mem.dynamic_arena_allocator(&arena))
		defer mem.tracking_allocator_destroy(&track)
		context.allocator = mem.tracking_allocator(&track)
		defer context.allocator = base_allocator
		cfg := engine.config_default()
		cfg.canvas_width, cfg.canvas_height, cfg.frame_rate = 40, 12, 0
		cfg.ignore_terminal_dimensions, cfg.virtual_clock = true, true
		rand.reset_u64(42)
		e, err := engine.engine_make(
			"Playback storage\nA B C D\nFinal row",
			cfg,
			context.allocator,
		)
		testing.expect(t, err == .None)
		fx, ok := effects.make_effect(kind, nil)
		testing.expect(t, ok)
		effects.build_effect(&fx, &e)
		free_all(context.temp_allocator)
		allocations := track.total_allocation_count
		frames := 0
		for frames < 50_000 {
			ids, alive := effects.next_frame(&fx, &e)
			if !alive do break
			if ids == nil {engine.frame_build_all(&e)} else {engine.frame_build_selected(&e, ids)}
			free_all(context.temp_allocator)
			frames += 1
		}
		testing.expect(t, frames < 50_000)
		testing.expect_value(t, track.total_allocation_count, allocations)
	}
}
