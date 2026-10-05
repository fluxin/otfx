package engine

import "core:math"
import "core:math/linalg"

// Values moving between two endpoints. Every kind keeps its own rule: colors
// step with TerminalTextEffects' integer channel deltas, so palettes match what
// users know; color pairs step each lane that has a target; coordinates, HSL
// colors and scalars interpolate linearly. Callers apply any easing to the step or
// fraction they pass, and own when a tween advances.
tween :: proc {
	tween_color,
	tween_colors,
	tween_coord,
	tween_hsl,
	tween_scalar,
}

// Step `step` of `steps`. Step `steps` is exactly `to`.
tween_color :: proc(from, to: Color, steps, step: int) -> Color #no_bounds_check {
	assert(steps >= 1 && step >= 0 && step <= steps)
	if step == steps do return to
	start := [3]int{int(from.r), int(from.g), int(from.b)}
	delta := [3]int {
		math.floor_div(int(to.r) - start.r, steps),
		math.floor_div(int(to.g) - start.g, steps),
		math.floor_div(int(to.b) - start.b, steps),
	}
	return {
		u8(clamp(start.r + delta.r * step, 0, 255)),
		u8(clamp(start.g + delta.g * step, 0, 255)),
		u8(clamp(start.b + delta.b * step, 0, 255)),
	}
}

// A lane without a target is cleared; a lane without a start jumps to its target.
tween_colors :: proc(from, to: Color_Pair, steps, step: int) -> Color_Pair {
	result := to
	if start, ok := from.fg.?; ok {
		if target, ok := to.fg.?; ok do result.fg = tween_color(start, target, steps, step)
	}
	if start, ok := from.bg.?; ok {
		if target, ok := to.bg.?; ok do result.bg = tween_color(start, target, steps, step)
	}
	return result
}

// Fraction `t` of the way along the line, rounded to a terminal cell.
tween_coord :: #force_inline proc(from, to: Coord, t: f64) -> Coord {
	return rounded_coord(linalg.lerp(coord_vec(from), coord_vec(to), t))
}

// Each HSL component moves linearly; hue takes the direct path, not the short
// way around the wheel. Tweening only lightness scales brightness.
tween_hsl :: #force_inline proc(from, to: HSL_Color, t: f64) -> HSL_Color {
	return {math.lerp(from.h, to.h, t), math.lerp(from.s, to.s, t), math.lerp(from.l, to.l, t)}
}

tween_scalar :: #force_inline proc(from, to, t: f64) -> f64 {
	return math.lerp(from, to, t)
}

// A pair of endpoints, for tables built from many tweens.
Tween :: struct($T: typeid) {
	from, to: T,
}

// Foreground tweens from one start color to each final color.
tweens_from :: proc(start: Color, finals: []Color, allocator := context.temp_allocator) -> []Tween(Appearance) {
	tweens := make([]Tween(Appearance), len(finals), allocator)
	for final, i in finals do tweens[i] = {from = {colors = {fg = start}}, to = {colors = {fg = final}}}
	return tweens
}

// Shared appearances for a table of styles, `steps + 1` per row, prepared once
// so effects select an ID instead of encoding a private color per cell. A
// step that repeats the previous style reuses its ID, so moving onto it
// publishes nothing.
Appearance_Ramp :: struct {
	codes: []Appearance_Id, // row * (steps + 1) + step
	steps: int,
}

ramp_from_styles :: proc(
	e: ^Engine,
	styles: []Appearance,
	steps: int,
	allocator := context.allocator,
) -> Appearance_Ramp {
	assert(steps >= 1 && len(styles) % (steps + 1) == 0)
	codes := make([]Appearance_Id, len(styles), allocator)
	for style, i in styles {
		repeat := i % (steps + 1) > 0 && style.colors == styles[i - 1].colors && style.bold == styles[i - 1].bold
		codes[i] = repeat ? codes[i - 1] : prepare_appearance(e, style)
	}
	return {codes, steps}
}

// A row per color tween; each step takes the tween's `to` bold.
ramp_make :: proc(
	e: ^Engine,
	tweens: []Tween(Appearance),
	steps: int,
	allocator := context.allocator,
) -> Appearance_Ramp {
	styles := make([]Appearance, len(tweens) * (steps + 1), context.temp_allocator)
	for tw, row in tweens {
		for step in 0 ..= steps {
			styles[row * (steps + 1) + step] = {
				colors = tween(tw.from.colors, tw.to.colors, steps, step),
				bold   = tw.to.bold,
			}
		}
	}
	return ramp_from_styles(e, styles, steps, allocator)
}

// The prepared appearance for `step` of row `index`.
ramp_code :: #force_inline proc(r: Appearance_Ramp, index, step: int) -> Appearance_Id #no_bounds_check {
	return r.codes[index * (r.steps + 1) + step]
}

// The nearest step to fraction `t` in [0, 1] of row `index`.
ramp_code_at :: #force_inline proc(r: Appearance_Ramp, index: int, t: f64) -> Appearance_Id {
	return ramp_code(r, index, clamp(round_to_int(t * f64(r.steps)), 0, r.steps))
}
