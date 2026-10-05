package engine

import "core:math"
import "core:math/ease"
import "core:math/linalg"
import "core:simd"
import "core:strings"

// Coordinates, path geometry, rounding, and easing names.

Coord :: struct {
	column: int,
	row:    int,
}

coord :: proc(column, row: int) -> Coord {
	return {column, row}
}

round_to_int :: #force_inline proc(x: f64) -> int {
	return int(simd.extract(simd.nearest(#simd[2]f64{x, 0}), 0))
}

// Round both terminal coordinates together, preserving signed ties to even.
rounded_coord :: #force_inline proc(p: linalg.Vector2f64) -> Coord {
	rounded := simd.nearest(#simd[2]f64{p.x, p.y})
	return {int(simd.extract(rounded, 0)), int(simd.extract(rounded, 1))}
}

// Terminal cells are ~2:1; row deltas are doubled when requested.
line_length :: proc(a, b: Coord, double_row_diff: bool) -> f64 {
	v := coord_vec(b) - coord_vec(a)
	if double_row_diff do v *= linalg.Vector2f64{1, 2}
	return linalg.length(v)
}

// Compare against a squared radius when the actual distance is not needed.
line_length_squared :: proc(a, b: Coord, double_row_diff: bool) -> f64 {
	v := coord_vec(b) - coord_vec(a)
	if double_row_diff do v *= linalg.Vector2f64{1, 2}
	return linalg.length2(v)
}

coord_vec :: proc(c: Coord) -> linalg.Vector2f64 {
	return {f64(c.column), f64(c.row)}
}

// Every effect path currently uses at most one control point. Keep the
// quadratic De Casteljau hot path fixed-size and allocation-free.
coord_on_quadratic_bezier :: #force_inline proc(start, control, end: Coord, t: f64) -> Coord {
	a := linalg.lerp(coord_vec(start), coord_vec(control), t)
	b := linalg.lerp(coord_vec(control), coord_vec(end), t)
	p := linalg.lerp(a, b, t)
	return rounded_coord(p)
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
	limit := coords_limit != 0 ? coords_limit : round_to_int(math.TAU * f64(radius))
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
		point := coord(round_to_int(p.x), round_to_int(p.y))
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
	return tween(origin, target, (base + offset_from_target) / base)
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
