package regression

import "../src/engine"
import "core:mem"
import "core:strings"
import "core:testing"

@(test)
pending_rows_preserve_completed_frame :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 1, 2
	cfg.ignore_terminal_dimensions, cfg.no_color = true, true
	e, err := engine.engine_make("A\nB", cfg)
	testing.expect_value(t, err, engine.Input_Error.None)
	for id in e.particle_sets.input do engine.set_particle(&e, id, engine.Visible(true))
	engine.frame_build(&e)
	completed := engine.frame_bytes(&e, context.allocator)
	// Multiple edits queue the next frame without changing the completed one.
	id := e.particle_sets.input[0]
	engine.set_symbol(&e, id, 'X')
	engine.set_symbol(&e, id, 'Y')
	testing.expect_value(t, string(engine.frame_bytes(&e)), string(completed))
	engine.frame_build(&e)
	testing.expect_value(t, string(frame_without_padding(&e)), "Y")
	engine.frame_build(&e)
	testing.expect_value(t, len(engine.frame_bytes(&e)), 0)
}

@(test)
frame_capture_owns_its_bytes :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 1, 1
	cfg.ignore_terminal_dimensions, cfg.no_color = true, true
	e, err := engine.engine_make("A", cfg)
	testing.expect_value(t, err, engine.Input_Error.None)
	id := e.particle_sets.input[0]
	engine.set_particle(&e, id, engine.Visible(true))
	captured: []byte
	for symbol, frame in ([]rune{'A', 'B', 'B'}) {
		defer free_all(context.temp_allocator)
		engine.set_symbol(&e, id, symbol)
		engine.frame_build(&e)
		if frame == 0 do captured = frame_without_padding(&e, context.allocator)
		expected := "A" if frame == 0 else "B" if frame == 1 else ""
		testing.expect_value(t, string(frame_without_padding(&e)), expected)
		testing.expect_value(t, string(captured), "A")
	}
	testing.expect_value(t, string(captured), "A")
}

@(test)
row_bytes_preserve_fixed_cell_slots :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	for no_color in ([]bool{false, true}) {
		cfg := engine.config_default()
		cfg.canvas_width, cfg.canvas_height = 65, 2
		cfg.ignore_terminal_dimensions, cfg.no_color = true, no_color
		e, err := engine.engine_make("A", cfg)
		testing.expect_value(t, err, engine.Input_Error.None)
		for id in 0 ..< len(e.particles) do engine.set_particle(&e, engine.Particle_Id(id), engine.Visible(true))
		engine.frame_build(&e)
		glyphs := []rune{'A', 'é', '░', '𐍈', '�', 0}
		builder := strings.builder_make()
		// Sparse and dense edits use the same fixed-slot update path.
		// Repeated changes before emission must use the final appearance.
		for tick in 0 ..< 48 {
			count := 65 if tick % 4 == 0 else 3
			for i in 0 ..< count {
				id := engine.Particle_Id((i * 17 + tick * 13) % len(e.particles))
				engine.set_symbol(&e, id, glyphs[(i + tick) % len(glyphs)])
				engine.set_foreground(&e, id, engine.Color{u8(tick), 2, 3})
				background: Maybe(engine.Color)
				if tick % 2 != 0 do background = engine.Color{4, 5, 6}
				engine.set_background(&e, id, background)
				if i == 0 do engine.set_symbol(&e, id, glyphs[(tick + 3) % len(glyphs)])
				engine.set_particle(&e, id, engine.Visible(tick % 5 != 0))
			}
			engine.frame_build(&e)
			for row in 0 ..< 2 {
				strings.builder_reset(&builder)
				for cell in e.rows[row].cells {
					id := cell.top
					if id <
					   0 {strings.write_byte(&builder, ' ')} else {engine.write_particle(&e, id, &builder)}
				}
				actual := strings.builder_make(allocator = context.temp_allocator)
				for b in e.rows[row].bytes do if b != 0 do strings.write_byte(&actual, b)
				testing.expect_value(t, strings.to_string(actual), strings.to_string(builder))
			}
		}
	}
}

@(test)
fixed_slots_share_grid_and_clear_shorter_glyphs :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	for no_color in ([]bool{false, true}) {
		cfg := engine.config_default()
		cfg.canvas_width, cfg.canvas_height = 2, 2
		cfg.ignore_terminal_dimensions, cfg.no_color = true, no_color
		e, err := engine.engine_make("AB\nCD", cfg)
		testing.expect_value(t, err, engine.Input_Error.None)
		stride := 4 if no_color else 51
		testing.expect_value(t, e.cell_stride, stride)
		for &row, i in e.rows {
			testing.expect_value(t, len(row.bytes), 2 * stride)
			testing.expect(t, raw_data(row.bytes) == &e.canvas_bytes[i * 2 * stride])
			testing.expect(t, raw_data(row.cells) == &e.cells[i * 2])
		}
		for id in e.particle_sets.input do engine.set_particle(&e, id, engine.Visible(true))
		id := e.particle_sets.input[0]
		expected_glyphs := []string{"𐍈", "A", ""}
		for glyph, index in ([]rune{'𐍈', 'A', 0}) {
			engine.set_symbol(&e, id, glyph)
			engine.frame_build(&e)
			slot := e.canvas_bytes[:stride]
			expected := expected_glyphs[index]
			testing.expect_value(t, string(slot[:len(expected)]), expected)
			for b in slot[len(expected):] do testing.expect_value(t, b, u8(0))
			// Its neighbor retains its location, regardless of glyph byte length.
			testing.expect_value(t, e.canvas_bytes[stride], u8('B'))
		}
		engine.set_particle(&e, id, engine.Visible(false))
		engine.frame_build(&e)
		testing.expect_value(t, e.canvas_bytes[0], u8(' '))
		for b in e.canvas_bytes[1:stride] do testing.expect_value(t, b, u8(0))
	}
}
