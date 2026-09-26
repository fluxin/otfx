package regression

import "../src/engine"
import "core:mem"
import "core:strings"
import "core:testing"

@(test)
shared_appearance_dirty_updates_all_top_cells :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 2, 1
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("AB", cfg)
	testing.expect_value(t, err, engine.Input_Error.None)
	shared := engine.prepare_appearance(
		&e,
		engine.Appearance{colors = {fg = engine.Color{255, 0, 0}}},
	)
	b := e.particle_sets.input[1]
	for id in e.particle_sets.input {
		engine.set_appearance(&e, id, shared)
		engine.set_visible(&e, id, true)
	}
	engine.frame_build(&e)

	// The flag invalidates encoded bytes; it does not schedule particle changes.
	e.shared_appearances[shared - 1].colors.fg = engine.Color{0, 255, 0}
	engine.dirty_appearance(&e.shared_appearances[shared - 1])
	engine.frame_build(&e)
	testing.expect_value(t, len(frame_without_padding(&e)), 0)
	testing.expect(t, e.shared_appearances[shared - 1].dirty)
	// A caller editing shared storage directly queues every affected particle.
	for id in e.particle_sets.input do engine.set_appearance(&e, id, shared)
	engine.frame_build(&e)
	testing.expect(t, !e.shared_appearances[shared - 1].dirty)
	expect_visible_draws(t, &e)

	// Returning to an already encoded shared appearance must still update the cell.
	engine.set_foreground(&e, b, engine.Color{0, 0, 255})
	engine.frame_build(&e)
	engine.set_appearance(&e, b, shared)
	engine.set_symbol(&e, b, 'X')
	engine.frame_build(&e)
	expect_visible_draws(t, &e)
	engine.frame_build(&e)
	testing.expect_value(t, len(frame_without_padding(&e)), 0)
}

@(test)
appearance_prefix_survives_glyph_changes_and_private_edits :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	for mode in 0 ..< 3 {
		cfg := engine.config_default()
		cfg.canvas_width, cfg.canvas_height = 2, 1
		cfg.ignore_terminal_dimensions = true
		cfg.no_color, cfg.xterm_colors = mode == 1, mode == 2
		e, err := engine.engine_make("AB", cfg)
		testing.expect_value(t, err, engine.Input_Error.None)
		red := engine.Appearance {
			colors = {fg = engine.Color{255, 0, 0}},
			bold = true,
		}
		shared := engine.prepare_appearance(&e, red)
		other := engine.prepare_appearance(&e, red)
		testing.expect(t, shared != other)
		a := engine.add_particle(&e, 'A', shared, {1, 1})
		b := engine.add_particle(&e, 'B', other, {2, 1})
		engine.set_visible(&e, a, true)
		engine.set_visible(&e, b, true)
		preview := strings.builder_make(0, 51)
		engine.write_particle(&e, a, &preview)
		testing.expect(t, e.shared_appearances[shared - 1].dirty)
		engine.frame_build(&e)
		testing.expect(t, !e.shared_appearances[shared - 1].dirty)
		expect_visible_draws(t, &e)
		shared_prefix := e.shared_appearances[shared - 1].bytes
		// A private edit rebuilds its own prefix without replacing shared red.
		engine.set_foreground(&e, a, engine.Color{0, 0, 255})
		engine.frame_build(&e)
		expect_appearance(t, engine.get_appearance(&e, b), red)
		expect_visible_draws(t, &e)
		testing.expect_value(t, e.shared_appearances[shared - 1].bytes, shared_prefix)
		private_prefix := e.particles.private_appearance[a].bytes
		// Reuse styles with an ASCII, four-byte, and empty glyph.
		for symbol in ([]rune{'B', '𐍈', 0, 'A'}) {
			engine.set_symbol(&e, a, symbol)
			testing.expect(t, !e.particles.private_appearance[a].dirty)
			testing.expect_value(t, e.particles.private_appearance[a].bytes, private_prefix)
			engine.frame_build(&e)
			strings.builder_reset(&preview)
			engine.write_particle(&e, a, &preview)
			encoded := strings.to_string(preview)
			testing.expect_value(t, string(e.rows[0].bytes[:len(encoded)]), encoded)
			for byte in e.rows[0].bytes[len(encoded):e.cell_stride] {
				testing.expect_value(t, byte, u8(0))
			}
		}
		// A caller edits logical fields on a returned value; its old bytes must be ignored.
		changed := engine.get_appearance(&e, a)
		changed.colors.bg = engine.Color{0, 255, 0}
		changed.bold = false
		engine.set_appearance(&e, a, changed)
		engine.set_bold(&e, a, true)
		engine.set_bold(&e, a, false)
		engine.compose_frame(&e)
		testing.expect(t, e.particles.private_appearance[a].dirty)
		testing.expect_value(t, e.particles.private_appearance[a].bytes, private_prefix)
		engine.frame_build(&e)
		testing.expect(t, !e.particles.private_appearance[a].dirty)
		expect_visible_draws(t, &e)
		// A hidden particle leaves its prefix stale until a dirty cell needs it.
		engine.set_visible(&e, b, false)
		engine.set_bold(&e, b, false)
		engine.frame_build(&e)
		testing.expect(t, e.particles.private_appearance[b].dirty)
		engine.set_visible(&e, b, true)
		engine.frame_build(&e)
		testing.expect(t, !e.particles.private_appearance[b].dirty)
		engine.set_appearance(&e, a, shared)
		engine.frame_build(&e)
		expect_visible_draws(t, &e)
	}
}
