package regression

import "../src/engine"
import "core:mem"
import "core:testing"

@(test)
dirty_rows_emit_only_changed_rows :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 2, 3
	cfg.ignore_terminal_dimensions, cfg.no_color = true, true
	e, err := engine.engine_make("A\nB\nC", cfg, context.allocator)
	testing.expect_value(t, err, engine.Input_Error.None)
	for id in e.particle_sets.input do engine.set_particle(&e, id, visible = true)
	a, b, c := e.particle_sets.input[0], e.particle_sets.input[1], e.particle_sets.input[2]
	engine.frame_build(&e)
	testing.expect_value(t, frame_text(&e), "A \x1b[1EB \x1b[1EC ")
	engine.frame_build(&e)
	testing.expect_value(t, len(engine.frame_bytes(&e)), 0)
	engine.set_symbol(&e, b, "b")
	testing.expect_value(t, e.rows[0].flags != {}, false)
	testing.expect_value(t, e.rows[1].flags != {}, true)
	testing.expect_value(t, e.rows[2].flags != {}, false)
	engine.frame_build(&e)
	testing.expect_value(t, frame_text(&e), "\x1b[1Eb ")
	engine.set_particle(&e, b, coord = engine.Coord{2, 1})
	engine.frame_build(&e)
	testing.expect_value(t, frame_text(&e), "\x1b[1E  \x1b[1ECb")
	engine.set_particle(&e, c, visible = false)
	engine.frame_build(&e)
	testing.expect_value(t, frame_text(&e), "\x1b[1E\x1b[1E b")
	// Selection removal erases old rows even without a particle mutation.
	engine.frame_build(&e, []engine.Particle_Id{a})
	testing.expect_value(t, frame_text(&e), "\x1b[1E\x1b[1E  ")
	engine.frame_build(&e, []engine.Particle_Id{a, a})
	testing.expect_value(t, len(engine.frame_bytes(&e)), 0)
	engine.frame_build(&e)
	testing.expect_value(t, frame_text(&e), "\x1b[1E\x1b[1E b")
	engine.set_particle(&e, a, coord = engine.Coord{1, 5})
	engine.frame_build(&e)
	testing.expect_value(t, frame_text(&e), "  ")
	engine.frame_build(&e)
	testing.expect_value(t, len(engine.frame_bytes(&e)), 0)
}
