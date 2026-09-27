package regression

import "../src/engine"
import "core:container/xar"
import "core:testing"

@(test)
intrusive_cells_keep_links_across_growth_and_covered_reentry :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 1, 1
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("A", cfg)
	testing.expect_value(t, err, engine.Input_Error.None)
	base := e.particle_sets.input[0]
	appearance := e.particles[base].initial_appearance_id
	engine.set_placement(&e, base, {1, 1}, true, 10)
	engine.frame_build(&e)
	base_node := xar.get_ptr(&e.render_nodes, base)
	ids: [1024]engine.Particle_Id
	for &id, i in ids {
		id = engine.add_particle(&e, 'B', appearance, {1, 1})
		engine.set_placement(&e, id, {1, 1}, true, i % 7)
	}
	engine.frame_build(&e)
	testing.expect_value(t, xar.get_ptr(&e.render_nodes, base), base_node)
	testing.expect_value(t, e.cells[0].top, base)
	testing.expect(t, e.cells[0].unordered)
	expect_published_cells(t, &e)

	// Covered removal must unlink immediately without sorting or dirtying pixels.
	engine.set_visible(&e, ids[333], false)
	engine.frame_build(&e)
	testing.expect_value(t, e.cells[0].top, base)
	testing.expect_value(t, len(cell_keys(e.cells[0])), len(ids))
	testing.expect(t, e.cells[0].unordered)
	engine.set_visible(&e, ids[333], true)
	engine.frame_build(&e)
	testing.expect_value(t, len(cell_keys(e.cells[0])), len(ids) + 1)
	expect_published_cells(t, &e)

	// Losing the winner and changing a covered priority in one queue resolves
	// from final membership, then the new winner can be popped normally.
	engine.set_visible(&e, base, false)
	engine.set_layer(&e, ids[0], engine.Layer(20))
	engine.frame_build(&e)
	testing.expect_value(t, e.cells[0].top, ids[0])
	testing.expect(t, !e.cells[0].unordered)
	expect_published_cells(t, &e)
	engine.set_visible(&e, ids[0], false)
	engine.frame_build(&e)
	expect_published_cells(t, &e)
	// It can return on a different layer without retaining an old membership.
	engine.set_placement(&e, base, {1, 1}, true, 30)
	engine.frame_build(&e)
	testing.expect_value(t, e.cells[0].top, base)
	expect_published_cells(t, &e)
}
