package engine

import "core:fmt"
import "core:math"
import "core:math/ease"
import "core:math/linalg"
import "core:strconv"
import "core:strings"
import ansi "core:terminal/ansi"

// ---------------------------------------------------------------------------
// geometry
// ---------------------------------------------------------------------------

Coord :: struct {
	column: int,
	row:    int,
}

coord :: proc(column, row: int) -> Coord {
	return {column, row}
}

round_half_even :: proc(x: f64) -> int {
	floor := math.floor(x)
	diff := x - floor
	if diff > 0.5 do return int(floor) + 1
	if diff < 0.5 do return int(floor)
	f := int(floor)
	return f if f % 2 == 0 else f + 1
}

// Terminal cells are ~2:1; row deltas are doubled when requested.
line_length :: proc(a, b: Coord, double_row_diff: bool) -> f64 {
	v := coord_vec(b) - coord_vec(a)
	if double_row_diff do v *= linalg.Vector2f64{1, 2}
	return linalg.length(v)
}

coord_vec :: proc(c: Coord) -> linalg.Vector2f64 {
	return {f64(c.column), f64(c.row)}
}

coord_on_line :: #force_inline proc(start, end: Coord, t: f64) -> Coord {
	p := linalg.lerp(coord_vec(start), coord_vec(end), t)
	return {round_half_even(p.x), round_half_even(p.y)}
}

// Every effect path currently uses at most one control point. Keep the
// quadratic De Casteljau hot path fixed-size and allocation-free.
coord_on_quadratic_bezier :: #force_inline proc(start, control, end: Coord, t: f64) -> Coord {
	a := linalg.lerp(coord_vec(start), coord_vec(control), t)
	b := linalg.lerp(coord_vec(control), coord_vec(end), t)
	p := linalg.lerp(a, b, t)
	return {round_half_even(p.x), round_half_even(p.y)}
}

quadratic_bezier_length :: proc(start, control, end: Coord) -> f64 {
	length := 0.0
	previous := start
	// Preserve ttfx semantics: sample through t=0.9, omitting the last span.
	for step in 1 ..< 10 {
		point := coord_on_quadratic_bezier(start, control, end, f64(step) / 10)
		length += line_length(previous, point, true)
		previous = point
	}
	return length
}

// Circle points as rotation-matrix * radial vector. Terminal cells are roughly
// twice as tall as they are wide, so double only the column offset.
find_coords_on_circle :: proc(
	origin: Coord,
	radius, coords_limit: int,
	unique: bool,
) -> [dynamic]Coord {
	points: [dynamic]Coord
	if radius == 0 do return points
	limit := coords_limit != 0 ? coords_limit : round_half_even(math.TAU * f64(radius))
	seen: [dynamic]Coord
	angle_step := math.TAU / f64(limit)
	radial := linalg.Vector2f64{f64(radius), 0}
	origin_v := coord_vec(origin)
	for i in 0 ..< limit {
		angle := angle_step * f64(i)
		rot := linalg.matrix2_rotate(angle)
		q := rot * radial
		q.x *= 2
		p := origin_v + q
		point := coord(round_half_even(p.x), round_half_even(p.y))
		if unique {
			dup := false
			for q2 in seen {
				if q2 == point {
					dup = true
					break
				}
			}
			if dup do continue
			append(&seen, point)
		}
		append(&points, point)
	}
	return points
}

find_coords_in_rect :: proc(origin: Coord, distance: int) -> [dynamic]Coord {
	coords: [dynamic]Coord
	if distance == 0 do return coords
	reserve(&coords, (2 * distance + 1) * (2 * distance + 1))
	for column in origin.column - distance ..= origin.column + distance {
		for row in origin.row - distance ..= origin.row + distance {
			append(&coords, coord(column, row))
		}
	}
	return coords
}

// TerminalTextEffects calls this a circle; terminal cell aspect makes it an
// ellipse with horizontal radius diameter and vertical radius diameter/2.
find_coords_in_circle :: proc(center: Coord, diameter: int) -> [dynamic]Coord {
	coords: [dynamic]Coord
	if diameter == 0 do return coords
	a_squared := math.pow(f64(diameter), 2)
	b_squared := math.pow(f64(diameter) / 2, 2)
	for column in center.column - diameter ..= center.column + diameter {
		x := f64(column - center.column)
		x_component := math.pow(x, 2) / a_squared
		max_row_offset := int(math.sqrt(b_squared * (1 - x_component)))
		for row in center.row - max_row_offset ..= center.row + max_row_offset {
			append(&coords, coord(column, row))
		}
	}
	return coords
}

extrapolate_along_ray :: proc(origin, target: Coord, offset_from_target: f64) -> Coord {
	base := line_length(origin, target, false)
	if base == 0 do return target
	return coord_on_line(origin, target, (base + offset_from_target) / base)
}

find_normalized_distance_from_center :: proc(
	bottom, top, left, right: int,
	c: Coord,
) -> (
	f64,
	bool,
) {
	y_offset := bottom - 1
	x_offset := left - 1
	w := right - x_offset
	h := top - y_offset
	col := c.column - x_offset
	row := c.row - y_offset
	if col < 1 || col > w || row < 1 || row > h do return 0, false
	// Measure in the terminal's aspect-scaled coordinate space: one row is two
	// columns high. The full span's half-diagonal normalizes center to 0 and
	// the corners to 1.
	span := linalg.Vector2f64{f64(w), 2 * f64(h)}
	center := span * 0.5
	point := linalg.Vector2f64{f64(col), 2 * f64(row)}
	max_distance := linalg.length(span)
	distance := linalg.distance(center, point)
	return distance / (max_distance / 2), true
}

// ---------------------------------------------------------------------------
// colors & gradients
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// easing — named functions come from core:math/ease.
// ---------------------------------------------------------------------------

easing_parse :: proc(s: string) -> (ease.Ease, bool) {
	k: ease.Ease
	switch strings.to_lower(s) {
	case "linear":
		k = .Linear
	case "in_sine":
		k = .Sine_In
	case "out_sine":
		k = .Sine_Out
	case "in_out_sine":
		k = .Sine_In_Out
	case "in_quad":
		k = .Quadratic_In
	case "out_quad":
		k = .Quadratic_Out
	case "in_out_quad":
		k = .Quadratic_In_Out
	case "in_cubic":
		k = .Cubic_In
	case "out_cubic":
		k = .Cubic_Out
	case "in_out_cubic":
		k = .Cubic_In_Out
	case "in_quart":
		k = .Quartic_In
	case "out_quart":
		k = .Quartic_Out
	case "in_out_quart":
		k = .Quartic_In_Out
	case "in_quint":
		k = .Quintic_In
	case "out_quint":
		k = .Quintic_Out
	case "in_out_quint":
		k = .Quintic_In_Out
	case "in_expo":
		k = .Exponential_In
	case "out_expo":
		k = .Exponential_Out
	case "in_out_expo":
		k = .Exponential_In_Out
	case "in_circ":
		k = .Circular_In
	case "out_circ":
		k = .Circular_Out
	case "in_out_circ":
		k = .Circular_In_Out
	case "in_back":
		k = .Back_In
	case "out_back":
		k = .Back_Out
	case "in_out_back":
		k = .Back_In_Out
	case "in_elastic":
		k = .Elastic_In
	case "out_elastic":
		k = .Elastic_Out
	case "in_out_elastic":
		k = .Elastic_In_Out
	case "in_bounce":
		k = .Bounce_In
	case "out_bounce":
		k = .Bounce_Out
	case "in_out_bounce":
		k = .Bounce_In_Out
	case:
		return {}, false
	}
	return k, true
}

// Shared dense-timeline sampler used by effects that keep start ticks.
eased_timeline_index :: #force_inline proc(step, total_steps: int, fn: ease.Ease) -> int {
	assert(total_steps >= 1)
	ratio := f64(step) / f64(total_steps)
	factor := ease.ease(fn, ratio)
	return clamp(round_half_even(factor * f64(total_steps - 1)), 0, total_steps - 1)
}

// ---------------------------------------------------------------------------
// ansi
// ---------------------------------------------------------------------------

buf_append_decimal :: proc(buf: ^$Buffer, v: int) {
	if v >= 100 {
		append(buf, byte('0') + byte(v / 100))
	}
	if v >= 10 {
		append(buf, byte('0') + byte((v / 10) % 10))
	}
	append(buf, byte('0') + byte(v % 10))
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

buf_append_sgr_color :: proc(buf: ^$Buffer, selector: int, c: Color, xterm_colors: bool) {
	append(buf, ansi.CSI)
	buf_append_decimal(buf, selector)
	if xterm_colors {
		append(buf, ';', '5', ';')
		buf_append_decimal(buf, int(color_to_xterm(c)))
		append(buf, ansi.SGR)
		return
	}
	append(buf, ';', '2', ';')
	buf_append_decimal(buf, int(c.r))
	append(buf, ';')
	buf_append_decimal(buf, int(c.g))
	append(buf, ';')
	buf_append_decimal(buf, int(c.b))
	append(buf, ansi.SGR)
}

move_cursor_up :: proc(n: int) -> string {
	return fmt.tprintf("%s%d%s", ansi.CSI, n, ansi.CUU)
}
