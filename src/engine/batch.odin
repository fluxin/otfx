package engine

import "core:math/ease"

// Actions fill borrowed frame columns. The caller owns chunk size, lifetime,
// phase boundaries and playback; dispatch happens once per action, not sample.
Sequence_Frame :: struct {
	coord:  Coord,
	colors: Color_Pair,
}

Ease_Action :: struct {
	fn: ease.Ease,
}

Move_Action :: struct {
	from, to: Coord,
}

Palette_Action :: struct {
	colors: []Color,
	base:   Color_Pair,
	eased:  bool,
}

Gradient_Action :: struct {
	from, to:    Color_Pair,
	hold, steps: int,
}

Position_Action :: struct {
	value: Coord,
}
Colors_Action :: struct {
	value: Color_Pair,
}

Sequence_Action :: union {
	Ease_Action,
	Move_Action,
	Palette_Action,
	Gradient_Action,
	Position_Action,
	Colors_Action,
}

// Keypoint times are frame boundaries [start, stop). Easing samples the end
// of each frame: (tick + 1 - start) / (stop - start). Holds start at age zero.
// Keypoints apply in slice order; later actions can overwrite earlier columns.
Sequence_Keypoint :: struct {
	start, stop: int,
	actions:     []Sequence_Action,
}

sequence_batch :: proc(
	frames: #soa[]Sequence_Frame,
	factors: []f64,
	first_tick: int,
	keypoints: []Sequence_Keypoint,
) #no_bounds_check {
	assert(len(factors) >= len(frames))
	for keypoint in keypoints {
		assert(keypoint.stop >= keypoint.start)
		start := clamp(keypoint.start - first_tick, 0, len(frames))
		stop := clamp(keypoint.stop - first_tick, 0, len(frames))
		if start == stop do continue
		frames := frames[start:stop]
		factors := factors[start:stop]
		first := first_tick + start - keypoint.start
		for action in keypoint.actions {
			switch a in action {
			case Ease_Action:
				steps := keypoint.stop - keypoint.start
				for &factor, i in factors do factor = ease.ease(a.fn, f64(first + i + 1) / f64(steps))
			case Move_Action:
				for &coord, i in frames.coord[:len(frames)] do coord = tween(a.from, a.to, factors[i])
			case Palette_Action:
				assert(len(a.colors) > 0)
				for &colors, i in frames.colors[:len(frames)] {
					entry :=
						a.eased ? clamp(round_to_int(f64(len(a.colors) - 1) * factors[i]), 0, len(a.colors) - 1) : 0
					colors = a.base
					colors.fg = a.colors[entry]
				}
			case Gradient_Action:
				assert(a.hold > 0 && a.steps > 0)
				for &colors, i in frames.colors[:len(frames)] {
					colors = tween(a.from, a.to, a.steps, min((first + i) / a.hold, a.steps))
				}
			case Position_Action:
				for &coord in frames.coord[:len(frames)] do coord = a.value
			case Colors_Action:
				for &colors in frames.colors[:len(frames)] do colors = a.value
			}
		}
	}
}

// Batched sample updates.

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
) -> []Sample_Change #no_bounds_check {
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
eased_timeline_index :: #force_inline proc(step, total_steps: int, fn: ease.Ease) -> int #no_bounds_check {
	assert(total_steps >= 1)
	ratio := f64(step) / f64(total_steps)
	factor := ease.ease(fn, ratio)
	return clamp(round_to_int(factor * f64(total_steps - 1)), 0, total_steps - 1)
}
