package regression

import "../src/engine"
import "core:mem"
import "core:testing"

@(test)
new_particles_publish_through_update_queue :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 2, 1
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("A", cfg)
	testing.expect_value(t, err, engine.Input_Error.None)
	testing.expect_value(t, len(e.updates), len(e.particles))
	for update in e.updates do testing.expect_value(t, update.previous_cell, -1)
	base := e.particle_sets.input[0]
	// Direct build writes are gathered by the initialization entry too.
	e.particles[base].flags += {.Visible}
	engine.frame_build(&e)
	testing.expect_value(t, e.cells[0].top, base)
	testing.expect_value(t, len(e.updates), 0)

	shared := e.particles[base].initial_appearance_id
	added := engine.add_particle(&e, 'B', shared, {2, 1})
	engine.set_visible(&e, added, true)
	engine.set_position(&e, added, {1, 1})
	engine.set_layer(&e, added, 2)
	engine.set_symbol(&e, added, 'C')
	testing.expect_value(t, len(e.updates), 1)
	testing.expect_value(t, e.updates[0].previous_cell, -1)
	testing.expect_value(t, e.cells[0].top, base)
	engine.frame_build(&e)
	testing.expect_value(t, e.cells[0].top, added)
	testing.expect_value(t, len(e.cells[0].layers[2]), 1)
	testing.expect_value(t, string(frame_without_padding(&e)), "C ")

	// A new particle hidden again before rendering never joins the grid.
	hidden := engine.add_particle(&e, 'D', shared, {1, 1})
	engine.set_visible(&e, hidden, true)
	engine.set_visible(&e, hidden, false)
	engine.set_visible(&e, added, false)
	engine.frame_build(&e)
	testing.expect_value(t, e.cells[0].top, base)
	testing.expect_value(t, len(e.cells[0].layers[0]), 1)
	testing.expect_value(t, len(e.cells[0].layers[2]), 0)
	testing.expect_value(t, len(e.updates), 0)
	testing.expect(t, .Update_Queued not_in e.particles[hidden].flags)
}

@(test)
particle_flags_preserve_independent_state :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 2, 1
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("A", cfg)
	testing.expect_value(t, err, engine.Input_Error.None)
	id := e.particle_sets.input[0]
	e.particles[id].flags += {.Fill, .Preserve_Initial_Colors}
	engine.set_visible(&e, id, true)
	engine.frame_build(&e)
	expected: engine.Particle_Flags = {.Visible, .Fill, .Preserve_Initial_Colors}
	testing.expect_value(t, e.particles[id].flags, expected)

	engine.set_position(&e, id, {2, 1})
	testing.expect_value(t, e.particles[id].flags, expected + {.Update_Queued})
	engine.set_visible(&e, id, false)
	testing.expect_value(t, e.particles[id].flags, (expected - {.Visible}) + {.Update_Queued})
	engine.set_placement(&e, id, {2, 1}, true, 1)
	testing.expect_value(t, len(e.updates), 1)
	testing.expect_value(t, e.particles[id].flags, expected + {.Update_Queued})
	engine.frame_build(&e)
	testing.expect_value(t, e.particles[id].flags, expected)
	testing.expect_value(t, e.cells[1].top, id)
}

@(test)
particle_requested_state_publishes_once :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 3, 1
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("ABC", cfg)
	testing.expect_value(t, err, engine.Input_Error.None)
	a, b, c := e.particle_sets.input[0], e.particle_sets.input[1], e.particle_sets.input[2]
	for id in e.particle_sets.input do engine.set_visible(&e, id, true)
	engine.frame_build(&e)

	engine.set_position(&e, a, {2, 1})
	engine.set_position(&e, a, {3, 1})
	engine.set_position(&e, a, {2, 1})
	engine.set_layer(&e, a, 2)
	engine.set_symbol(&e, a, 'X')
	engine.set_foreground(&e, a, engine.Color{255, 0, 0})
	engine.set_layer(&e, b, 4)
	engine.set_position(&e, c, {1, 1})
	testing.expect_value(t, len(e.updates), 3)
	// Getters expose requested values; the published cells and bytes stay unchanged.
	testing.expect_value(t, e.particles[a].current_coord, engine.Coord{2, 1})
	testing.expect_value(t, e.particles[a].symbol, rune('X'))
	testing.expect_value(t, e.particles[b].layer, 4)
	testing.expect_value(t, e.cells[0].top, a)
	testing.expect_value(t, e.cells[1].top, b)
	testing.expect_value(t, e.cells[2].top, c)
	testing.expect_value(t, string(frame_without_padding(&e)), "ABC")
	engine.frame_build(&e)
	testing.expect_value(t, len(e.updates), 0)
	testing.expect_value(t, string(frame_without_padding(&e)), "CB ")
	testing.expect(t, e.particles.private_appearance[a].dirty)

	// Removing the winner exposes the final state of the covered particle.
	engine.set_visible(&e, b, false)
	engine.set_visible(&e, c, false)
	engine.frame_build(&e)
	testing.expect_value(t, e.cells[1].top, a)
	testing.expect(t, !e.particles.private_appearance[a].dirty)
	expect_visible_draws(t, &e)

	// A round trip before publication leaves exactly one membership.
	layer_count := len(e.cells[1].layers)
	engine.set_visible(&e, a, false)
	engine.set_position(&e, a, {-1, 1})
	engine.set_position(&e, a, {2, 1})
	engine.set_visible(&e, a, true)
	engine.set_layer(&e, a, 7)
	engine.set_layer(&e, a, 2)
	testing.expect_value(t, len(e.updates), 1)
	engine.frame_build(&e)
	// Publication may repatch the final winner; it never installs intermediate placement.
	testing.expect_value(t, len(e.cells[1].layers), layer_count)
	testing.expect(t, (.Update_Queued not_in e.particles[a].flags))
	testing.expect_value(t, len(e.cells[1].layers[2]), 1)
	testing.expect_value(t, e.cells[1].layers[2][0], a)
	engine.frame_build(&e)
	testing.expect_value(t, len(frame_without_padding(&e)), 0)

	// Guards compare requested values, so returning to red/X preserves both edits.
	engine.set_foreground(&e, a, engine.Color{0, 0, 255})
	engine.set_foreground(&e, a, engine.Color{255, 0, 0})
	engine.set_symbol(&e, a, 'Y')
	engine.set_symbol(&e, a, 'X')
	testing.expect_value(t, len(e.updates), 1)
	testing.expect_value(t, e.particles[a].symbol, rune('X'))
	testing.expect_value(
		t,
		engine.get_appearance(&e, a).colors.fg,
		Maybe(engine.Color)(engine.Color{255, 0, 0}),
	)
	engine.frame_build(&e)
	testing.expect_value(t, e.particles[a].symbol, rune('X'))
	testing.expect_value(
		t,
		engine.get_appearance(&e, a).colors.fg,
		Maybe(engine.Color)(engine.Color{255, 0, 0}),
	)

	green := engine.prepare_appearance(
		&e,
		engine.Appearance{colors = {fg = engine.Color{0, 255, 0}}, bold = true},
	)
	engine.set_appearance(&e, a, green)
	engine.set_foreground(&e, a, engine.Color{0, 0, 255})
	engine.set_appearance(&e, a, green)
	testing.expect_value(t, len(e.updates), 1)
	engine.frame_build(&e)
	testing.expect_value(t, e.particles[a].shared_appearance_id, green)
	testing.expect(t, engine.get_appearance(&e, a).bold)
	engine.set_appearance(&e, a, green)
	engine.set_foreground(&e, a, engine.Color{255, 0, 0})
	engine.frame_build(&e)
	testing.expect_value(t, e.particles[a].shared_appearance_id, engine.NO_APPEARANCE)
	testing.expect(t, engine.get_appearance(&e, a).bold)
	testing.expect_value(
		t,
		engine.get_appearance(&e, a).colors.fg,
		Maybe(engine.Color)(engine.Color{255, 0, 0}),
	)
}
