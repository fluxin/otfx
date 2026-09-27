package regression

import "../src/engine"
import "core:mem"
import "core:testing"

@(test)
timeline_bulk_fill_replaces_reused_columns :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	frames: engine.Frame_Timeline
	style := engine.Appearance {
		colors = {fg = engine.Color{1, 2, 3}, bg = engine.Color{4, 5, 6}},
		bold = true,
		dirty = true,
	}
	for &byte in style.bytes do byte = 255
	first := engine.create_timeline(&frames, 'X', style, 7, 8)
	testing.expect_value(t, first, engine.Span{0, 8})
	resize(&frames, 1) // Subsequent spans reuse nonzero appearance/glyph/duration storage.
	gradient := engine.create_timeline(
		&frames,
		'é',
		2,
		engine.Color{0, 0, 0},
		engine.Color{30, 60, 90},
		3,
	)
	hold := engine.create_timeline(&frames, 'A', engine.Appearance{}, 1, 2)
	testing.expect_value(t, gradient, engine.Span{1, 4})
	testing.expect_value(t, hold, engine.Span{5, 2})
	testing.expect_value(t, frames[0], engine.Frame{'X', style, 7})
	for i in 0 ..< gradient.len {
		appearance := engine.Appearance {
			colors = {fg = engine.Color{u8(i * 10), u8(i * 20), u8(i * 30)}},
		}
		testing.expect_value(t, frames[gradient.start + i], engine.Frame{'é', appearance, 2})
	}
	for i in hold.start ..< len(frames) do testing.expect_value(t, frames[i], engine.Frame{'A', {}, 1})
}

@(test)
batch_timeline_preserves_holds_skips_and_reactivation :: proc(t: ^testing.T) {
	starts := [3]int{0, 2, 20}
	previous := [3]int{-1, -1, -1}
	samples := [5]int{0, 0, 1, 1, 2}
	storage: [3]engine.Sample_Change
	changes := engine.sample_timeline_changes(storage[:], starts[:], previous[:], 0, samples[:])
	testing.expect_value(t, len(changes), 1)
	testing.expect_value(t, changes[0], engine.Sample_Change{0, 0})
	changes = engine.sample_timeline_changes(storage[:], starts[:], previous[:], 1, samples[:])
	testing.expect_value(t, len(changes), 0)
	changes = engine.sample_timeline_changes(storage[:], starts[:], previous[:], 2, samples[:])
	testing.expect_value(t, len(changes), 2)
	testing.expect_value(t, changes[0], engine.Sample_Change{0, 1})
	testing.expect_value(t, changes[1], engine.Sample_Change{1, 0})
	// A skipped tick samples the current value without replaying old writes.
	changes = engine.sample_timeline_changes(storage[:], starts[:], previous[:], 10, samples[:])
	testing.expect_value(t, len(changes), 2)
	for change in changes do testing.expect_value(t, change.sample, 2)
	changes = engine.sample_timeline_changes(storage[:], starts[:], previous[:], 11, samples[:])
	testing.expect_value(t, len(changes), 0)
	starts[0], previous[0] = 11, -1
	changes = engine.sample_timeline_changes(storage[:], starts[:], previous[:], 11, samples[:])
	testing.expect_value(t, len(changes), 1)
	testing.expect_value(t, changes[0], engine.Sample_Change{0, 0})
	changes = engine.sample_timeline_changes(nil, nil, nil, 0, samples[:])
	testing.expect_value(t, len(changes), 0)
}
