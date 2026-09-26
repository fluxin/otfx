package engine

import "core:math/ease"

// Frame timeline construction and batched sample updates.

Frame :: struct {
	visual:   Visual,
	duration: int,
}

// Effect-owned frame lanes use this contiguous SoA storage. Construction is
// shared; each effect owns activation, tick arithmetic, and completion.
Frame_Timeline :: #soa[dynamic]Frame

timeline_append_frame :: #force_inline proc(
	frames: ^Frame_Timeline,
	visual: Visual,
	duration: int,
) {
	assert(duration >= 1)
	append(frames, Frame{visual, duration})
}

create_hold_timeline :: proc(
	frames: ^Frame_Timeline,
	visual: Visual,
	duration, count: int,
) -> Span {
	assert(count >= 1)
	start := len(frames^)
	for _ in 0 ..< count do timeline_append_frame(frames, visual, duration)
	return {start, count}
}

create_gradient_timeline :: proc(
	frames: ^Frame_Timeline,
	symbol: string,
	duration: int,
	start, end: Color,
	steps: int,
) -> Span {
	assert(steps >= 1)
	timeline_start := len(frames^)
	for step in 0 ..= steps {
		timeline_append_frame(
			frames,
			Visual{symbol, gradient_between_step(start, end, steps, step), nil, false},
			duration,
		)
	}
	return {timeline_start, steps + 1}
}

create_timeline :: proc {
	create_hold_timeline,
	create_gradient_timeline,
}

// Spread a shorter sequence across a longer gradient/symbol lane. Earlier
// values receive the remainder, matching Python's apply_gradient_to_symbols.
sequence_expand :: proc(values: []$T, count: int) -> [dynamic]T {
	assert(len(values) > 0 && count >= len(values))
	out := make([dynamic]T, 0, count)
	for value, i in values {
		for _ in 0 ..< count / len(values) + int(i < count % len(values)) {
			append(&out, value)
		}
	}
	return out
}

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

// Shared dense-timeline sampler used by effects that keep start ticks.
eased_timeline_index :: #force_inline proc(step, total_steps: int, fn: ease.Ease) -> int {
	assert(total_steps >= 1)
	ratio := f64(step) / f64(total_steps)
	factor := ease.ease(fn, ratio)
	return clamp(round_half_even(factor * f64(total_steps - 1)), 0, total_steps - 1)
}
