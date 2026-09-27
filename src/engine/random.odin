package engine

import "base:intrinsics"

// The one random stream for construction and playback. Effects need cheap,
// reproducible noise, not statistical rigor: splitmix64 inlines at each call
// site, and bounded draws use a multiply-shift instead of dividing. Its bias,
// at most n/2^64, cannot show in an animation. Each thread owns its stream,
// so parallel tests stay deterministic.

@(thread_local)
random_state: u64

random_seed :: proc "contextless" (seed: u64) {
	random_state = seed
}

random_seed_from_clock :: proc "contextless" () {
	random_state = u64(intrinsics.read_cycle_counter())
}

random_u64 :: #force_inline proc "contextless" () -> u64 {
	random_state += 0x9E3779B97F4A7C15
	z := random_state
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return z ~ (z >> 31)
}

// A draw from [0, n).
random_below :: #force_inline proc(n: int) -> int {
	assert(n > 0)
	return int((u128(random_u64()) * u128(n)) >> 64)
}

// A draw from [lo, hi).
random_range :: #force_inline proc(lo, hi: int) -> int {
	assert(lo < hi)
	return lo + random_below(hi - lo)
}

// A draw from [0, 1) with 53 random mantissa bits.
random_float :: #force_inline proc "contextless" () -> f64 {
	return f64(random_u64() >> 11) / (1 << 53)
}

// A draw from [lo, hi), or lo when the bounds are equal.
random_float_range :: #force_inline proc(lo, hi: f64) -> f64 {
	assert(lo <= hi)
	return lo + (hi - lo) * random_float()
}

// Fisher-Yates.
random_shuffle :: proc(values: $T/[]$E) {
	for i := len(values) - 1; i > 0; i -= 1 {
		j := random_below(i + 1)
		values[i], values[j] = values[j], values[i]
	}
}
