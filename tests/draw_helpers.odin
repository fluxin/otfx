package regression

import "../src/engine"
import "core:container/bit_array"
import "core:testing"

// Frames carry no slot padding; this also strips any NUL a test glyph emits.
frame_without_padding :: proc(e: ^engine.Engine, allocator := context.temp_allocator) -> []byte {
	bytes := engine.frame_bytes(e, allocator)
	used := 0
	for b in bytes {
		if b == 0 do continue
		bytes[used] = b
		used += 1
	}
	return bytes[:used]
}

// Existing composition witnesses use bottom-up logical canvas indices.
draw_at :: proc(e: ^engine.Engine, cell: int) -> i32 {
	width, height := e.layout.visible_right, e.layout.visible_top
	top_down := (height - 1 - cell / width) * width + cell % width
	if id := e.cells[top_down].top; id != engine.NO_PARTICLE do return i32(id)
	return -1
}

// A cell's slot holds exactly what the terminal last received for it.
expect_frame_cell :: proc(
	t: ^testing.T,
	e: ^engine.Engine,
	column, row: int,
	expected_symbol: rune,
	expected: engine.Appearance,
) {
	encoded := engine.cell_encoding(e, row * e.layout.visible_right + column)
	lines, err := engine.preprocess_input(string(encoded), 4)
	testing.expect_value(t, err, engine.Input_Error.None)
	actual_symbol := ' '
	actual := engine.Appearance{}
	if len(lines) > 0 && lines[0].width > 0 {
		actual = lines[0].cells[0].style
		actual_symbol = lines[0].cells[0].symbol
	}
	testing.expect_value(t, actual_symbol, expected_symbol)
	expect_appearance(t, actual, expected)
}

expect_visible_draws :: proc(t: ^testing.T, e: ^engine.Engine) {
	lines, err := engine.preprocess_input(string(frame_without_padding(e)), 4)
	testing.expect_value(t, err, engine.Input_Error.None)
	for entry, index in e.cells {
		id := entry.top
		// A delta contains only rewritten cells. The rest remain on screen.
		if id == engine.NO_PARTICLE || !bit_array.get(&e.emit_cells, index) do continue
		row, col := index / e.layout.visible_right, index % e.layout.visible_right
		expected := engine.get_render_appearance(e, id)^
		if e.cfg.no_color do expected.colors.fg, expected.colors.bg, expected.bold = nil, nil, false
		testing.expect(t, row < len(lines) && col < lines[row].width)
		if row >= len(lines) || col >= lines[row].width do continue
		cell := lines[row].cells[col]
		actual := cell.style
		testing.expect_value(t, cell.symbol, e.particles[id].symbol)
		expect_appearance(t, actual, expected)
	}
}

// Derived bytes are engine/config-specific; compare the public style fields here.
expect_appearance :: proc(t: ^testing.T, actual, expected: engine.Appearance) {
	testing.expect_value(t, actual.colors, expected.colors)
	testing.expect_value(t, actual.bold, expected.bold)
}

// Effect-only tests still advance through the render boundary before reading values.
step_frame :: proc(next: $F, state: $S, e: ^engine.Engine) -> bool {
	alive := next(state, e)
	if alive do engine.frame_build(e)
	return alive
}
