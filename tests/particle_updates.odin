package regression

import "../src/engine"
import "core:mem"
import "core:testing"

@(test)
queued_layer_changes_keep_published_stack_order :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 2, 1
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("AB", cfg)
	testing.expect_value(t, err, engine.Input_Error.None)
	a, b := e.particle_sets.input[0], e.particle_sets.input[1]
	appearance := e.particles[a].initial_appearance_id
	c := engine.add_particle(&e, 'C', appearance, {1, 1})
	d := engine.add_particle(&e, 'D', appearance, {1, 1})
	ids := [?]engine.Particle_Id{a, b, c, d}
	for id, i in ids do engine.set_placement(&e, id, {1, 1}, true, i)
	engine.frame_build(&e)
	// A is inserted above C's published key before C's queued layer change.
	// B then departs from the interior of that still-sorted stack.
	engine.set_layer(&e, a, 2)
	engine.set_layer(&e, c, 0)
	engine.set_position(&e, b, {2, 1})
	engine.set_visible(&e, d, false)
	engine.frame_build(&e)
	testing.expect_value(t, string(frame_without_padding(&e)), "AB")
	testing.expect_value(t, len(cell_keys(e.cells[0])), 2)
	testing.expect_value(t, cell_keys(e.cells[0])[0].id, u32(c))
	testing.expect_value(t, cell_keys(e.cells[0])[1].id, u32(a))
	expect_published_cells(t, &e)

	// Arrival precedes departure in each destination cell.
	engine.set_position(&e, a, {2, 1})
	engine.set_position(&e, b, {1, 1})
	engine.frame_build(&e)
	testing.expect_value(t, string(frame_without_padding(&e)), "BA")
	expect_published_cells(t, &e)
}

@(test)
queued_departures_resolve_final_cell_membership :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 2, 1
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("A", cfg)
	testing.expect_value(t, err, engine.Input_Error.None)
	base := e.particle_sets.input[0]
	engine.set_visible(&e, base, true)
	ids: [24]engine.Particle_Id
	for &id in ids {
		id = engine.add_particle(&e, 'X', e.particles[base].initial_appearance_id, {1, 1})
		engine.set_placement(&e, id, {1, 1}, true, 1)
	}
	engine.frame_build(&e)
	when engine.FRAME_STATS_ENABLED {e.stats = {}}
	// Remove winners first, then publish the final departure batch including
	// one particle returning on a higher layer.
	for i := len(ids) - 1; i >= 0; i -= 1 do engine.set_position(&e, ids[i], {2, 1})
	engine.set_placement(&e, ids[0], {1, 1}, true, 3)
	engine.compose_frame(&e)
	testing.expect_value(t, e.cells[0].top, ids[0])
	testing.expect_value(t, e.cells[1].top, ids[len(ids) - 1])
	testing.expect_value(t, cell_layer_count(e.cells[0], 1), 0)
	testing.expect_value(t, cell_layer_count(e.cells[1], 1), len(ids) - 1)
	expect_published_cells(t, &e)
	when engine.FRAME_STATS_ENABLED {
		testing.expect_value(t, e.stats.ownership_visits, 0)
	}
	engine.set_visible(&e, ids[0], false)
	engine.frame_build(&e)
	testing.expect_value(t, e.cells[0].top, base)
}

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
	for id in e.updates {
		testing.expect_value(t, e.particles[id].cell, -1)
	}
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
	testing.expect_value(t, e.particles[added].cell, -1)
	testing.expect_value(t, e.cells[0].top, base)
	engine.frame_build(&e)
	testing.expect_value(t, e.cells[0].top, added)
	testing.expect_value(t, cell_layer_count(e.cells[0], 2), 1)
	testing.expect_value(t, string(frame_without_padding(&e)), "C ")

	// A new particle hidden again before rendering never joins the grid.
	hidden := engine.add_particle(&e, 'D', shared, {1, 1})
	engine.set_visible(&e, hidden, true)
	engine.set_visible(&e, hidden, false)
	engine.set_visible(&e, added, false)
	engine.frame_build(&e)
	testing.expect_value(t, e.cells[0].top, base)
	testing.expect_value(t, cell_layer_count(e.cells[0], 0), 1)
	testing.expect_value(t, cell_layer_count(e.cells[0], 2), 0)
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
	testing.expect_value(t, e.particles[id].flags, expected + {.Update_Queued, .Placement_Changed})
	engine.set_visible(&e, id, false)
	testing.expect_value(
		t,
		e.particles[id].flags,
		(expected - {.Visible}) + {.Update_Queued, .Placement_Changed},
	)
	engine.set_placement(&e, id, {2, 1}, true, 1)
	testing.expect_value(t, len(e.updates), 1)
	testing.expect_value(t, e.particles[id].flags, expected + {.Update_Queued, .Placement_Changed})
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
	// Requested coordinates/layers changed, but published membership has not.
	testing.expect_value(t, e.particles[a].cell, 0)
	testing.expect_value(t, e.particles[c].cell, 2)
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
	occupants := len(cell_keys(e.cells[1]))
	engine.set_visible(&e, a, false)
	engine.set_position(&e, a, {-1, 1})
	engine.set_position(&e, a, {2, 1})
	engine.set_visible(&e, a, true)
	engine.set_layer(&e, a, 7)
	engine.set_layer(&e, a, 2)
	testing.expect_value(t, len(e.updates), 1)
	engine.frame_build(&e)
	// A placement round trip neither changes membership nor repatches the winner.
	testing.expect_value(t, len(frame_without_padding(&e)), 0)
	testing.expect_value(t, len(cell_keys(e.cells[1])), occupants)
	testing.expect(t, (.Update_Queued not_in e.particles[a].flags))
	testing.expect_value(t, cell_layer_count(e.cells[1], 2), 1)
	expect_published_cells(t, &e)
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

@(test)
content_changes_follow_final_cell_winner :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 3, 1
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("AB", cfg)
	testing.expect_value(t, err, engine.Input_Error.None)
	a, b := e.particle_sets.input[0], e.particle_sets.input[1]
	engine.set_placement(&e, a, {1, 1}, true, 0)
	engine.set_placement(&e, b, {1, 1}, true, 1)
	engine.frame_build(&e)

	// Covered content remains lazy and emits nothing.
	engine.set_symbol(&e, a, 'X')
	engine.frame_build(&e)
	testing.expect_value(t, len(frame_without_padding(&e)), 0)
	testing.expect_value(t, e.cells[0].top, b)

	// Content-only publication preserves membership and updates the winner.
	engine.set_symbol(&e, b, 'Y')
	engine.frame_build(&e)
	testing.expect_value(t, string(frame_without_padding(&e)), "Y  ")
	testing.expect_value(t, cell_layer_count(e.cells[0], 1), 1)

	// A content edit queued before the covering particle departs is exposed.
	engine.set_symbol(&e, a, 'Z')
	engine.set_position(&e, b, {2, 1})
	engine.frame_build(&e)
	testing.expect_value(t, string(frame_without_padding(&e)), "ZY ")

	// Both change kinds must accumulate on the same entry, in either order.
	engine.set_symbol(&e, a, 'Q')
	engine.set_position(&e, a, {3, 1})
	testing.expect_value(t, len(e.updates), 1)
	engine.frame_build(&e)
	testing.expect_value(t, string(frame_without_padding(&e)), " YQ")
	engine.set_position(&e, a, {1, 1})
	engine.set_symbol(&e, a, 'R')
	testing.expect_value(t, len(e.updates), 1)
	engine.frame_build(&e)
	testing.expect_value(t, string(frame_without_padding(&e)), "RY ")

	// Content of an offscreen particle is retained until it enters the canvas.
	engine.set_position(&e, a, {-1, 1})
	engine.frame_build(&e)
	engine.set_symbol(&e, a, 'S')
	engine.frame_build(&e)
	testing.expect_value(t, len(frame_without_padding(&e)), 0)
	engine.set_position(&e, a, {1, 1})
	engine.frame_build(&e)
	testing.expect_value(t, string(frame_without_padding(&e)), "SY ")
}
