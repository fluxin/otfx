package engine

Sample_Change :: struct {
	slot:   int,
	sample: int,
}

// A small shared tick-to-sample table describes holds, not rendered frames.
// Each lane owns the fields it writes. Initialize previous to -1 on activation
// or after another writer changes those fields. Starts may be in the future.
// The final sample is held indefinitely; completion timing belongs to the caller.
sample_timeline_changes :: proc(
	out: []Sample_Change,
	starts, previous: []int,
	tick: int,
	samples: []int,
) -> []Sample_Change {
	assert(len(out) >= len(starts) && len(previous) == len(starts))
	assert(len(samples) > 0)
	count := 0
	for start, slot in starts {
		age := tick - start
		if age < 0 do continue
		sample := samples[min(age, len(samples) - 1)]
		if sample == previous[slot] do continue
		previous[slot] = sample
		out[count] = {slot, sample}
		count += 1
	}
	return out[:count]
}
