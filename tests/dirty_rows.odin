package regression

import "../src/engine"
import "core:container/bit_array"
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
	e, err := engine.engine_make("A\nB\nC", cfg)
	testing.expect_value(t, err, engine.Input_Error.None)
	for id in e.particle_sets.input do engine.set_particle(&e, id, engine.Visible(true))
	a, b, c := e.particle_sets.input[0], e.particle_sets.input[1], e.particle_sets.input[2]
	engine.frame_build(&e)
	testing.expect_value(t, string(frame_without_padding(&e)), "A \x1b[1EB \x1b[1EC ")
	engine.frame_build(&e)
	testing.expect_value(t, len(frame_without_padding(&e)), 0)
	engine.set_symbol(&e, b, 'b')
	testing.expect_value(t, bit_array.get(&e.dirty_rows, 0), false)
	testing.expect_value(t, bit_array.get(&e.dirty_rows, 1), false)
	testing.expect_value(t, bit_array.get(&e.dirty_rows, 2), false)
	engine.frame_build(&e)
	testing.expect_value(t, bit_array.get(&e.emit_rows, 1), true)
	testing.expect_value(t, string(frame_without_padding(&e)), "\x1b[1Eb ")
	engine.set_particle(&e, b, engine.Coord{2, 1})
	engine.frame_build(&e)
	testing.expect_value(t, string(frame_without_padding(&e)), "\x1b[1E  \x1b[1ECb")
	engine.set_particle(&e, c, engine.Visible(false))
	engine.frame_build(&e)
	testing.expect_value(t, string(frame_without_padding(&e)), "\x1b[2E b")
	// Visibility alone admits and removes particles from the renderer.
	engine.set_particle(&e, b, engine.Visible(false))
	engine.frame_build(&e)
	testing.expect_value(t, string(frame_without_padding(&e)), "\x1b[2E  ")
	engine.set_particle(&e, a, engine.Visible(true))
	engine.set_particle(&e, a, engine.Visible(true))
	engine.frame_build(&e)
	testing.expect_value(t, len(frame_without_padding(&e)), 0)
	engine.set_particle(&e, b, engine.Visible(true))
	engine.frame_build(&e)
	testing.expect_value(t, string(frame_without_padding(&e)), "\x1b[2E b")
	engine.set_particle(&e, a, engine.Coord{1, 5})
	engine.frame_build(&e)
	testing.expect_value(t, string(frame_without_padding(&e)), "  ")
	engine.frame_build(&e)
	testing.expect_value(t, len(frame_without_padding(&e)), 0)
}

@(test)
covered_appearance_waits_until_exposed :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 1, 1
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("A", cfg)
	testing.expect_value(t, err, engine.Input_Error.None)
	under := e.particle_sets.input[0]
	cover := engine.add_particle(&e, 'B', e.particles[under].initial_appearance_id, {1, 1})
	engine.set_visible(&e, under, true)
	engine.set_visible(&e, cover, true)
	engine.frame_build(&e)
	testing.expect_value(t, e.cells[0].top, cover)
	testing.expect(t, (.Visible in e.particles[under].flags))

	engine.set_foreground(&e, under, engine.Color{255, 0, 0})
	engine.set_symbol(&e, under, 'X')
	testing.expect(t, !bit_array.get(&e.dirty_rows, 0))
	testing.expect(t, !bit_array.get(&e.dirty_cells, 0))
	engine.frame_build(&e)
	testing.expect_value(t, len(frame_without_padding(&e)), 0)
	testing.expect(t, e.particles.private_appearance[under].dirty)

	engine.set_visible(&e, cover, false)
	engine.frame_build(&e)
	testing.expect_value(t, e.cells[0].top, under)
	testing.expect(t, !e.particles.private_appearance[under].dirty)
	expect_visible_draws(t, &e)
}

@(test)
visibility_removal_reentry_and_population_growth :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 3, 1
	cfg.ignore_terminal_dimensions, cfg.no_color = true, true
	e, err := engine.engine_make("ABC", cfg)
	testing.expect_value(t, err, engine.Input_Error.None)
	a, b, c := e.particle_sets.input[0], e.particle_sets.input[1], e.particle_sets.input[2]
	for id in ([]engine.Particle_Id{a, b, b}) do engine.set_particle(&e, id, engine.Visible(true))
	engine.frame_build(&e)
	testing.expect_value(t, string(frame_without_padding(&e)), "AB ")
	engine.set_particle(&e, a, engine.Visible(false))
	engine.set_particle(&e, b, engine.Visible(false))
	engine.set_particle(&e, c, engine.Visible(true))
	engine.frame_build(&e)
	testing.expect_value(t, string(frame_without_padding(&e)), "  C")
	engine.set_particle(&e, c, engine.Visible(false))
	engine.frame_build(&e)
	testing.expect_value(t, string(frame_without_padding(&e)), "   ")
	for id in e.particle_sets.input do engine.set_particle(&e, id, engine.Visible(true))
	engine.frame_build(&e)
	testing.expect_value(t, string(frame_without_padding(&e)), "ABC")
	engine.frame_build(&e)
	testing.expect_value(t, len(frame_without_padding(&e)), 0)
	added := engine.add_particle(
		&e,
		'D',
		engine.prepare_appearance(&e, engine.Appearance{}),
		{2, 1},
	)
	engine.set_particle(&e, added, engine.Visible(true))
	engine.frame_build(&e)
	testing.expect_value(t, string(frame_without_padding(&e)), "ADC")
	engine.set_particle(&e, b, engine.Visible(false))
	engine.set_particle(&e, added, engine.Visible(false))
	engine.frame_build(&e)
	testing.expect_value(t, string(frame_without_padding(&e)), "A C")
}
