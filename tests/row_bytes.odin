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
cell_slots_hold_final_encoding :: proc(t: ^testing.T) {
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
					if id := cell.top; id != engine.NO_PARTICLE {
						engine.write_particle(&e, id, &builder)
					} else {
						strings.write_byte(&builder, ' ')
					}
				}
				actual := strings.builder_make(allocator = context.temp_allocator)
				for column in 0 ..< len(e.rows[row].cells) {
					strings.write_bytes(&actual, engine.cell_encoding(&e, row * len(e.rows[row].cells) + column))
				}
				testing.expect_value(t, strings.to_string(actual), strings.to_string(builder))
			}
		}
	}
}

@(test)
slots_follow_cells_and_track_glyph_lengths :: proc(t: ^testing.T) {
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
		testing.expect_value(t, len(e.slots), len(e.cells))
		for &row, i in e.rows do testing.expect(t, raw_data(row.cells) == &e.cells[i * 2])
		for id in e.particle_sets.input do engine.set_particle(&e, id, engine.Visible(true))
		id := e.particle_sets.input[0]
		expected_glyphs := []string{"𐍈", "A", ""}
		for glyph, index in ([]rune{'𐍈', 'A', 0}) {
			engine.set_symbol(&e, id, glyph)
			engine.frame_build(&e)
			testing.expect_value(t, string(engine.cell_encoding(&e, 0)), expected_glyphs[index])
			// Its neighbor keeps its own slot, regardless of glyph byte length.
			testing.expect_value(t, string(engine.cell_encoding(&e, 1)), "B")
		}
		engine.set_particle(&e, id, engine.Visible(false))
		engine.frame_build(&e)
		testing.expect_value(t, string(engine.cell_encoding(&e, 0)), " ")
	}
}
