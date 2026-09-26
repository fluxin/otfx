package regression

import "../src/engine"
import "core:testing"

// Existing composition witnesses use bottom-up logical canvas indices.
draw_at :: proc(e: ^engine.Engine, cell: int) -> i32 {
	width, height := e.layout.visible_right, e.layout.visible_top
	top_down := (height - 1 - cell / width) * width + cell % width
	return i32(e.frame_particles[top_down])
}

expect_frame_cell :: proc(
	t: ^testing.T,
	e: ^engine.Engine,
	column, row: int,
	expected: engine.Visual,
) {
	lines, err := engine.preprocess_input(string(engine.frame_bytes(e)), 4)
	testing.expect_value(t, err, engine.Input_Error.None)
	actual := engine.Visual {
		symbol = " ",
	}
	if row < len(lines) && column < lines[row].width {
		cell := lines[row].cells[column]
		actual = cell.style
		actual.symbol = engine.rune_to_string(cell.symbol)
	}
	testing.expect_value(t, actual, expected)
}

expect_visible_draws :: proc(t: ^testing.T, e: ^engine.Engine) {
	lines, err := engine.preprocess_input(string(engine.frame_bytes(e)), 4)
	testing.expect_value(t, err, engine.Input_Error.None)
	for id, index in e.frame_particles {
		if id < 0 do continue
		row, col := index / e.layout.visible_right, index % e.layout.visible_right
		// A delta contains only rewritten rows. Held rows remain on screen.
		if row >= len(lines) || lines[row].width == 0 do continue
		expected := engine.get_render_visual(e, id)
		if e.cfg.no_color do expected.fg, expected.bg, expected.bold = nil, nil, false
		testing.expect(t, row < len(lines) && col < lines[row].width)
		if row >= len(lines) || col >= lines[row].width do continue
		cell := lines[row].cells[col]
		actual := cell.style
		actual.symbol = engine.rune_to_string(cell.symbol)
		testing.expect_value(t, actual, expected)
	}
}
