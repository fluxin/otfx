package regression

import "../src/engine"
import "core:testing"

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
