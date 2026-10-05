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

@(private = "file", rodata)
Ansi_16_Palette := [16]Color {
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

@(private = "file", rodata)
Xterm_Cube_Steps := [6]u8{0, 95, 135, 175, 215, 255}

xterm_to_rgb :: proc(code: u8) -> Color #no_bounds_check {
	c := int(code)
	switch {
	case c < 16:
		return Ansi_16_Palette[c]
	case c < 232:
		v := c - 16
		return {Xterm_Cube_Steps[v / 36], Xterm_Cube_Steps[(v / 6) % 6], Xterm_Cube_Steps[v % 6]}
	case:
		g := u8(8 + (c - 232) * 10)
		return {g, g, g}
	}
}

// Upstream builds gradients with integer floor-division channel deltas, not
// float lerp; keep that so palettes match what users know.
gradient_make :: proc(
	stops: []Color,
	steps: []int,
	do_loop: bool,
	allocator := context.allocator,
) -> [dynamic]Color {
	assert(len(stops) >= 1)
	assert(len(steps) >= 1)
	spectrum := make([dynamic]Color, allocator)
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
		range_start := len(spectrum) != 0 ? 1 : 0
		for i in range_start ..< step_count do append(&spectrum, tween(start, end, step_count, i))
		append(&spectrum, end)
	}
	return spectrum
}

gradient_color_at_fraction :: proc(spectrum: []Color, fraction: f64) -> Color {
	return spectrum[gradient_index_at_fraction(len(spectrum), fraction)]
}

gradient_index_at_fraction :: proc(count: int, fraction: f64) -> int {
	assert(fraction >= 0 && fraction <= 1)
	return clamp(int(math.ceil(fraction * f64(count))) - 1, 0, count - 1)
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
	return spectrum[gradient_sample_index(s, len(spectrum), c)]
}

// The spectrum index gradient_sample reads, for effects that key build-time
// tables by final color.
gradient_sample_index :: proc(s: Gradient_Sampler, count: int, c: Coord) -> int {
	switch s.direction {
	case .Vertical:
		return gradient_index_at_ratio(c.row - s.min_row + 1, s.max_row - s.min_row + 1, count)
	case .Horizontal:
		return gradient_index_at_ratio(c.column - s.min_col + 1, s.max_col - s.min_col + 1, count)
	case .Diagonal:
		return gradient_index_at_ratio(
			(c.row - s.min_row + 1) * 2 + c.column - s.min_col + 1,
			(s.max_row - s.min_row + 1) * 2 + s.max_col - s.min_col + 1,
			count,
		)
	case .Radial:
		distance, ok := find_normalized_distance_from_center(
			s.min_row,
			s.max_row,
			s.min_col,
			s.max_col,
			c,
		)
		if !ok do return 0
		return gradient_index_at_fraction(count, clamp(distance, 0.0, 1.0))
	}
	unreachable()
}

// Keep HSL in build state when one fixed color is adjusted repeatedly.
HSL_Color :: struct {
	h, s, l: f64,
}

color_to_hsl :: proc(color: Color) -> HSL_Color {
	rgba := linalg.Vector4f64{f64(color.r) / 255, f64(color.g) / 255, f64(color.b) / 255, 1}
	hsla := linalg.vector4_rgb_to_hsl(rgba)
	return {hsla.x, hsla.y, hsla.z}
}

adjust_color_brightness :: proc {
	adjust_rgb_brightness,
	adjust_hsl_brightness,
}

adjust_rgb_brightness :: proc(color: Color, brightness: f64) -> Color {
	return adjust_hsl_brightness(color_to_hsl(color), brightness)
}

adjust_hsl_brightness :: proc(color: HSL_Color, brightness: f64) -> Color {
	return hsl_to_color({color.h, color.s, clamp(color.l * brightness, 0.0, 1.0)})
}

hsl_to_color :: proc(color: HSL_Color) -> Color {
	rgba := linalg.vector4_hsl_to_rgb(color.h, color.s, color.l, 1)
	return {
		u8(round_to_int(rgba.x * 255)),
		u8(round_to_int(rgba.y * 255)),
		u8(round_to_int(rgba.z * 255)),
	}
}

@(private = "file")
xterm_cube_nearest :: #force_inline proc(v: u8) -> int {
	if v <= 47 do return 0
	if v <= 115 do return 1
	if v <= 155 do return 2
	if v <= 195 do return 3
	if v <= 235 do return 4
	return 5
}

color_to_xterm :: proc(c: Color) -> u8 #no_bounds_check {
	// Match ttfx's hexterm.py: mean absolute RGB distance, first code wins ties.
	// L1 distance on the 6x6x6 cube separates across channels, reducing the 216
	// cube entries to one exact candidate between ANSI-16 and the 24 grayscales.
	r, g, b := int(c.r), int(c.g), int(c.b)
	best_code := 0
	best_distance := 3 * 255 + 1
	for candidate, code in Ansi_16_Palette {
		distance := abs(r - int(candidate.r)) + abs(g - int(candidate.g)) + abs(b - int(candidate.b))
		if distance < best_distance {
			best_distance = distance
			best_code = code
		}
	}
	ir, ig, ib := xterm_cube_nearest(c.r), xterm_cube_nearest(c.g), xterm_cube_nearest(c.b)
	cube_distance :=
		abs(r - int(Xterm_Cube_Steps[ir])) +
		abs(g - int(Xterm_Cube_Steps[ig])) +
		abs(b - int(Xterm_Cube_Steps[ib]))
	if cube_distance < best_distance {
		best_distance = cube_distance
		best_code = 16 + 36 * ir + 6 * ig + ib
	}
	for step in 0 ..< 24 {
		gray := 8 + step * 10
		distance := abs(r - gray) + abs(g - gray) + abs(b - gray)
		if distance < best_distance {
			best_distance = distance
			best_code = 232 + step
		}
	}
	return u8(best_code)
}
