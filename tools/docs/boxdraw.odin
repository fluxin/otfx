package main

// Box drawing is generated from stem geometry rather than rasterized from the
// font. A glyph outline scaled to a 7x13 cell does not reach the cell edge, so
// synthgrid's grid came out as dashes instead of continuous rules. Stems are
// built to touch the cell boundary by construction, so neighbouring cells join.
//
// The same path also renders the 127 box characters decrypt scrambles through:
// axis-aligned rules stay crisp at this size where antialiased outlines blur.

Stem :: enum u8 {
	None,
	Light,
	Heavy,
	Double,
}

Box_Spec :: struct {
	up, down, left, right: Stem,
	dash:                  u8, // 0, or the number of dashes along the run
	diagonal:              u8, // 1 '/', 2 '\', 3 both
	arc:                   bool,
}

Box_First :: 0x2500
Box_Count :: 0x80

@(private = "file")
box_table: [Box_Count]Box_Spec

@(private = "file")
set :: proc "contextless" (code: rune, up, down, left, right: Stem, dash: u8 = 0, diagonal: u8 = 0, arc := false) {
	box_table[int(code) - Box_First] = {up, down, left, right, dash, diagonal, arc}
}

@(init)
box_table_init :: proc "contextless" () {
	N, L, H, D :: Stem.None, Stem.Light, Stem.Heavy, Stem.Double

	set('─', N, N, L, L);  set('━', N, N, H, H);  set('│', L, L, N, N);  set('┃', H, H, N, N)
	set('┄', N, N, L, L, 3);  set('┅', N, N, H, H, 3)
	set('┆', L, L, N, N, 3);  set('┇', H, H, N, N, 3)
	set('┈', N, N, L, L, 4);  set('┉', N, N, H, H, 4)
	set('┊', L, L, N, N, 4);  set('┋', H, H, N, N, 4)

	set('┌', N, L, N, L);  set('┍', N, L, N, H);  set('┎', N, H, N, L);  set('┏', N, H, N, H)
	set('┐', N, L, L, N);  set('┑', N, L, H, N);  set('┒', N, H, L, N);  set('┓', N, H, H, N)
	set('└', L, N, N, L);  set('┕', L, N, N, H);  set('┖', H, N, N, L);  set('┗', H, N, N, H)
	set('┘', L, N, L, N);  set('┙', L, N, H, N);  set('┚', H, N, L, N);  set('┛', H, N, H, N)

	set('├', L, L, N, L);  set('┝', L, L, N, H);  set('┞', H, L, N, L);  set('┟', L, H, N, L)
	set('┠', H, H, N, L);  set('┡', H, L, N, H);  set('┢', L, H, N, H);  set('┣', H, H, N, H)
	set('┤', L, L, L, N);  set('┥', L, L, H, N);  set('┦', H, L, L, N);  set('┧', L, H, L, N)
	set('┨', H, H, L, N);  set('┩', H, L, H, N);  set('┪', L, H, H, N);  set('┫', H, H, H, N)

	set('┬', N, L, L, L);  set('┭', N, L, H, L);  set('┮', N, L, L, H);  set('┯', N, L, H, H)
	set('┰', N, H, L, L);  set('┱', N, H, H, L);  set('┲', N, H, L, H);  set('┳', N, H, H, H)
	set('┴', L, N, L, L);  set('┵', L, N, H, L);  set('┶', L, N, L, H);  set('┷', L, N, H, H)
	set('┸', H, N, L, L);  set('┹', H, N, H, L);  set('┺', H, N, L, H);  set('┻', H, N, H, H)

	set('┼', L, L, L, L);  set('┽', L, L, H, L);  set('┾', L, L, L, H);  set('┿', L, L, H, H)
	set('╀', H, L, L, L);  set('╁', L, H, L, L);  set('╂', H, H, L, L);  set('╃', H, L, H, L)
	set('╄', H, L, L, H);  set('╅', L, H, H, L);  set('╆', L, H, L, H);  set('╇', H, L, H, H)
	set('╈', L, H, H, H);  set('╉', H, H, H, L);  set('╊', H, H, L, H);  set('╋', H, H, H, H)

	set('╌', N, N, L, L, 2);  set('╍', N, N, H, H, 2)
	set('╎', L, L, N, N, 2);  set('╏', H, H, N, N, 2)

	set('═', N, N, D, D);  set('║', D, D, N, N)
	set('╒', N, L, N, D);  set('╓', N, D, N, L);  set('╔', N, D, N, D)
	set('╕', N, L, D, N);  set('╖', N, D, L, N);  set('╗', N, D, D, N)
	set('╘', L, N, N, D);  set('╙', D, N, N, L);  set('╚', D, N, N, D)
	set('╛', L, N, D, N);  set('╜', D, N, L, N);  set('╝', D, N, D, N)
	set('╞', L, L, N, D);  set('╟', D, D, N, L);  set('╠', D, D, N, D)
	set('╡', L, L, D, N);  set('╢', D, D, L, N);  set('╣', D, D, D, N)
	set('╤', N, L, D, D);  set('╥', N, D, L, L);  set('╦', N, D, D, D)
	set('╧', L, N, D, D);  set('╨', D, N, L, L);  set('╩', D, N, D, D)
	set('╪', L, L, D, D);  set('╫', D, D, L, L);  set('╬', D, D, D, D)

	// Arcs are drawn as square corners: at seven pixels across, the curve is
	// smaller than the stem is thick.
	set('╭', N, L, N, L, 0, 0, true);  set('╮', N, L, L, N, 0, 0, true)
	set('╯', L, N, L, N, 0, 0, true);  set('╰', L, N, N, L, 0, 0, true)

	set('╱', N, N, N, N, 0, 1);  set('╲', N, N, N, N, 0, 2);  set('╳', N, N, N, N, 0, 3)

	set('╴', N, N, L, N);  set('╵', L, N, N, N);  set('╶', N, N, N, L);  set('╷', N, L, N, N)
	set('╸', N, N, H, N);  set('╹', H, N, N, N);  set('╺', N, N, N, H);  set('╻', N, H, N, N)
	set('╼', N, N, L, H);  set('╽', L, H, N, N);  set('╾', N, N, H, L);  set('╿', H, L, N, N)
}

// Rows a horizontal rule occupies, and columns a vertical one occupies. A
// double rule is two runs with a one pixel gap, so each stem can need two rects.
@(private = "file")
stem_runs :: proc(weight: Stem, extent: int) -> (runs: [2][2]int, count: int) {
	center := (extent - 1) / 2
	switch weight {
	case .None:
		return
	case .Light:
		return {{center, center + 1}, {}}, 1
	case .Heavy:
		return {{center - 1, center + 1}, {}}, 1
	case .Double:
		return {{center - 1, center}, {center + 1, center + 2}}, 2
	}
	return
}

// Falls back to a light rule's footprint so a stem with no crossing partner
// still has a well defined join.
@(private = "file")
stem_band :: proc(a, b: Stem, extent: int) -> (low, high: int) {
	weight := a if a > b else b
	if weight == .None do weight = .Light
	runs, count := stem_runs(weight, extent)
	low, high = runs[0][0], runs[0][1]
	if count == 2 do high = runs[1][1]
	return
}

box_for :: proc(ch: rune) -> (shape: Cell_Shape, ok: bool) {
	index := int(ch) - Box_First
	if index < 0 || index >= Box_Count do return {}, false
	spec := box_table[index]
	if spec == {} do return {}, false

	shape.dash = spec.dash
	shape.diagonal = spec.diagonal
	shape.density = 255
	if spec.diagonal != 0 do return shape, true

	// Horizontal stems run along the rows the horizontal rule occupies and stop
	// at the far side of the vertical rule, so corners meet with no notch.
	column_low, column_high := stem_band(spec.up, spec.down, Cell_Width)
	row_low, row_high := stem_band(spec.left, spec.right, Cell_Height)

	add :: proc(shape: ^Cell_Shape, x0, y0, x1, y1: int) {
		if shape.count >= len(shape.rects) do return
		shape.rects[shape.count] = {x0, y0, x1, y1}
		shape.count += 1
	}

	rows, row_count := stem_runs(spec.left if spec.left != .None else spec.right, Cell_Height)
	for run in rows[:row_count] {
		if spec.left != .None do add(&shape, 0, run[0], column_high, run[1])
		if spec.right != .None do add(&shape, column_low, run[0], Cell_Width, run[1])
	}

	columns, column_count := stem_runs(spec.up if spec.up != .None else spec.down, Cell_Width)
	for run in columns[:column_count] {
		if spec.up != .None do add(&shape, run[0], 0, run[1], row_high)
		if spec.down != .None do add(&shape, run[0], row_low, run[1], Cell_Height)
	}
	return shape, shape.count > 0
}
