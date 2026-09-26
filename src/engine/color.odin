package engine

import "core:math"
import "core:math/linalg"
import "core:strconv"
import "core:strings"

// RGB and xterm colors, gradients, and brightness transforms.

Color :: struct {
	r, g, b: u8,
}

color_from_hex :: proc(s: string) -> (Color, bool) {
	t := strings.trim_left(s, "#")
	t = strings.trim_right(t, "#")
	if len(t) != 6 do return {}, false
	v, ok := strconv.parse_uint(t, 16)
	if !ok do return {}, false
	return {u8(v >> 16), u8(v >> 8), u8(v)}, true
}

// ttfx CLI colors: <= 3 characters is an xterm-256 code, otherwise hex.
parse_cli_color :: proc(s: string) -> (Color, bool) {
	if len(s) <= 3 {
		v, ok := strconv.parse_int(s)
		if !ok || v < 0 || v > 255 do return {}, false
		return xterm_to_rgb(u8(v)), true
	}
	return color_from_hex(s)
}

xterm_to_rgb :: proc(code: u8) -> Color {
	c := int(code)
	base := [16]Color {
		{0, 0, 0},
		{128, 0, 0},
		{0, 128, 0},
		{128, 128, 0},
		{0, 0, 128},
		{128, 0, 128},
		{0, 128, 128},
		{192, 192, 192},
		{128, 128, 128},
		{255, 0, 0},
		{0, 255, 0},
		{255, 255, 0},
		{0, 0, 255},
		{255, 0, 255},
		{0, 255, 255},
		{255, 255, 255},
	}
	switch {
	case c < 16:
		return base[c]
	case c < 232:
		v := c - 16
		step :: proc(n: int) -> u8 {return n == 0 ? 0 : u8(55 + n * 40)}
		return {step(v / 36), step((v / 6) % 6), step(v % 6)}
	case:
		g := u8(8 + (c - 232) * 10)
		return {g, g, g}
	}
}

// Upstream builds gradients with integer floor-division channel deltas, not
// float lerp; keep that so palettes match what users know.
gradient_make :: proc(stops: []Color, steps: []int, do_loop: bool) -> [dynamic]Color {
	spectrum: [dynamic]Color
	assert(len(stops) >= 1)
	assert(len(steps) >= 1)
	if len(stops) == 1 {
		for _ in 0 ..< steps[0] do append(&spectrum, stops[0])
		return spectrum
	}
	pair_count := len(stops) - 1 + int(do_loop)
	for pair in 0 ..< pair_count {
		step_count := steps[min(pair, len(steps) - 1)]
		assert(step_count >= 1)
		start := stops[pair]
		end := stops[(pair + 1) % len(stops)]
		start_r, start_g, start_b := int(start.r), int(start.g), int(start.b)
		delta_r := math.floor_div(int(end.r) - start_r, step_count)
		delta_g := math.floor_div(int(end.g) - start_g, step_count)
		delta_b := math.floor_div(int(end.b) - start_b, step_count)
		range_start := len(spectrum) != 0 ? 1 : 0
		for i in range_start ..< step_count {
			append(
				&spectrum,
				Color {
					u8(clamp(start_r + delta_r * i, 0, 255)),
					u8(clamp(start_g + delta_g * i, 0, 255)),
					u8(clamp(start_b + delta_b * i, 0, 255)),
				},
			)
		}
		append(&spectrum, end)
	}
	return spectrum
}

// Sample the same integer-delta interpolation used by gradient_make without
// materializing the two-stop gradient. Index == steps is the exact end color.
gradient_between_step :: proc(start, end: Color, steps, index: int) -> Color {
	assert(steps >= 1 && index >= 0 && index <= steps)
	if index == steps do return end
	start_r, start_g, start_b := int(start.r), int(start.g), int(start.b)
	delta_r := math.floor_div(int(end.r) - start_r, steps)
	delta_g := math.floor_div(int(end.g) - start_g, steps)
	delta_b := math.floor_div(int(end.b) - start_b, steps)
	return {
		u8(clamp(start_r + delta_r * index, 0, 255)),
		u8(clamp(start_g + delta_g * index, 0, 255)),
		u8(clamp(start_b + delta_b * index, 0, 255)),
	}
}

gradient_color_at_fraction :: proc(spectrum: []Color, fraction: f64) -> Color {
	assert(fraction >= 0 && fraction <= 1)
	n := len(spectrum)
	index := clamp(int(math.ceil(fraction * f64(n))) - 1, 0, n - 1)
	return spectrum[index]
}

gradient_index_at_ratio :: #force_inline proc(numerator, denominator, count: int) -> int {
	assert(denominator >= 1 && count >= 1)
	// ceil(numerator * count / denominator) - 1, clamped to the palette.
	return clamp(math.floor_div(numerator * count - 1, denominator), 0, count - 1)
}

Gradient_Direction :: enum {
	Vertical,
	Horizontal,
	Radial,
	Diagonal,
}

gdir_parse :: proc(s: string) -> (Gradient_Direction, bool) {
	switch s {
	case "vertical":
		return .Vertical, true
	case "horizontal":
		return .Horizontal, true
	case "radial":
		return .Radial, true
	case "diagonal":
		return .Diagonal, true
	}
	return .Vertical, false
}

// Gradient sampling state is just bounds and direction. Effects walk their
// character SoA once and derive the color directly; there is no canvas-sized
// lookup table or associative map to allocate and fill first.
Gradient_Sampler :: struct {
	min_row, max_row: int,
	min_col, max_col: int,
	direction:        Gradient_Direction,
}

gradient_sampler :: proc(
	min_row, max_row, min_col, max_col: int,
	dir: Gradient_Direction,
) -> Gradient_Sampler {
	return {min_row, max_row, min_col, max_col, dir}
}

gradient_sample :: proc(s: Gradient_Sampler, spectrum: []Color, c: Coord) -> Color {
	switch s.direction {
	case .Vertical:
		return(
			spectrum[gradient_index_at_ratio(c.row - s.min_row + 1, s.max_row - s.min_row + 1, len(spectrum))] \
		)
	case .Horizontal:
		return(
			spectrum[gradient_index_at_ratio(c.column - s.min_col + 1, s.max_col - s.min_col + 1, len(spectrum))] \
		)
	case .Diagonal:
		return(
			spectrum[gradient_index_at_ratio((c.row - s.min_row + 1) * 2 + c.column - s.min_col + 1, (s.max_row - s.min_row + 1) * 2 + s.max_col - s.min_col + 1, len(spectrum))] \
		)
	case .Radial:
		distance, ok := find_normalized_distance_from_center(
			s.min_row,
			s.max_row,
			s.min_col,
			s.max_col,
			c,
		)
		if !ok do return spectrum[0]
		return gradient_color_at_fraction(spectrum, clamp(distance, 0.0, 1.0))
	}
	unreachable()
}

// RGB -> HSL -> RGB brightness adjustment (beams/highlight/matrix).
adjust_color_brightness :: proc(color: Color, brightness: f64) -> Color {
	rgba := linalg.Vector4f64{f64(color.r) / 255, f64(color.g) / 255, f64(color.b) / 255, 1}
	hsla := linalg.vector4_rgb_to_hsl(rgba)
	hsla *= linalg.Vector4f64{1, 1, brightness, 1}
	hsla.z = clamp(hsla.z, 0.0, 1.0)
	rgba = linalg.vector4_hsl_to_rgb(hsla.x, hsla.y, hsla.z, hsla.w)
	return {
		u8(round_half_even(rgba.x * 255)),
		u8(round_half_even(rgba.y * 255)),
		u8(round_half_even(rgba.z * 255)),
	}
}

color_to_xterm :: proc(c: Color) -> u8 {
	// Match ttfx's hexterm.py: mean absolute RGB distance, first code wins ties.
	// The division by three is order preserving, so the integer sum is enough.
	best_code := 0
	best_distance := 3 * 255 + 1
	for code in 0 ..< 256 {
		candidate := xterm_to_rgb(u8(code))
		distance :=
			abs(int(c.r) - int(candidate.r)) +
			abs(int(c.g) - int(candidate.g)) +
			abs(int(c.b) - int(candidate.b))
		if distance < best_distance {
			best_distance = distance
			best_code = code
		}
	}
	return u8(best_code)
}
