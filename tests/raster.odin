package regression

import "../src/engine"
import "core:mem"
import "core:strings"
import "core:testing"

// Independent full-paint oracle: no retained membership or dirty state.
raster_expected :: proc(e: ^engine.Engine, selected: []engine.Particle_Id, all: bool, out: []i32) {
	for &cell in out do cell = -1
	for id in 0 ..< len(e.particles) {
		included := all
		for candidate in selected do included ||= int(candidate) == id
		if !included || !e.particles.is_visible[id] do continue
		p := e.particles.current_coord[id]
		row, column := p.row + e.layout.row_offset, p.column + e.layout.col_offset
		if row < e.layout.visible_bottom ||
		   row > e.layout.visible_top ||
		   column < e.layout.visible_left ||
		   column > e.layout.visible_right {
			continue
		}
		cell := &out[(row - 1) * e.layout.visible_right + column - 1]
		if cell^ < 0 ||
		   e.particles.layer[id] > e.particles.layer[cell^] ||
		   (e.particles.layer[id] == e.particles.layer[cell^] && id > int(cell^)) {
			cell^ = i32(id)
		}
	}
}

@(test)
frame_composition_matches_full_paint :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	// Exercise bitmap tails and rows sharing a word, plus character growth
	// across membership words. Overlaps include different and equal layers.
	for width in ([]int{1, 7, 63, 64, 65}) {
		cfg := engine.config_default()
		cfg.canvas_width, cfg.canvas_height = width, 3
		cfg.ignore_terminal_dimensions = true
		e, err := engine.engine_make("ABC\nD", cfg, context.allocator)
		testing.expect_value(t, err, engine.Input_Error.None)
		expected := make([]i32, width * 3)
		selected: [dynamic]engine.Particle_Id
		for tick in 0 ..< 90 {
			if tick == 30 || tick == 60 {
				for _ in 0 ..< 65 do engine.add_particle(&e, "X", {1, 1})
			}
			clear(&selected)
			for id in 0 ..< len(e.particles) {
				// Include clipping and crowded cells; leave positions unchanged
				// on alternate ticks to exercise independent layer/visual changes.
				engine.set_particle(
					&e,
					engine.Particle_Id(id),
					visible = (id + tick) % 5 != 0,
					layer = (id + tick / 3) % 4 - 2,
					coord = engine.Coord{(id * 7 + tick / 2) % (width + 2), (id + tick / 4) % 5},
				)
				engine.set_symbol(&e, engine.Particle_Id(id), "X" if (id + tick) % 2 == 0 else "Y")
				engine.set_foreground(&e, engine.Particle_Id(id), engine.Color{u8(tick), 100, 200})
				if tick % 7 != 0 && (id + tick) % 3 != 0 {
					append(&selected, engine.Particle_Id(id))
					if id % 11 == 0 do append(&selected, engine.Particle_Id(id))
				}
			}
			all := tick % 4 == 0
			raster_expected(&e, selected[:], all, expected)
			if all {
				engine.compose_frame(&e)
				engine.frame_build(&e)
			} else {
				engine.compose_frame(&e, selected[:])
				engine.frame_build(&e, selected[:])
			}
			for cell, index in expected do testing.expect_value(t, draw_at(&e, index), cell)
			// Rebuilding preserves the same visible appearance.
			if all {engine.frame_build(&e)} else {engine.frame_build(&e, selected[:])}
			expect_visible_draws(t, &e)
		}
	}
}

@(test)
frame_composition_keeps_pending_visual_changes :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 65, 2
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("A", cfg, context.allocator)
	testing.expect_value(t, err, engine.Input_Error.None)
	id := e.particle_sets.input[0]
	e.particles.is_visible[id] = true
	e.particles.current_coord[id] = {65, 2}
	engine.frame_build(&e)
	expect_frame_cell(t, &e, 64, 0, engine.Visual{symbol = "A"})
	// Update without emission, then move again. Only the latest position is
	// drawn, but the last emitted position must still be erased.
	engine.set_particle(&e, id, coord = engine.Coord{1, 1})
	engine.compose_frame(&e)
	engine.set_particle(&e, id, coord = engine.Coord{2, 1})
	engine.set_symbol(&e, engine.Particle_Id(id), "B")
	engine.frame_build(&e)
	expect_frame_cell(t, &e, 64, 0, engine.Visual{symbol = " "})
	expect_frame_cell(t, &e, 1, 1, engine.Visual{symbol = "B"})
	engine.frame_build(&e)
	expect_visible_draws(t, &e)
}

@(test)
particle_settings_preserve_omitted_values :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 3, 1
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("A", cfg, context.allocator)
	testing.expect_value(t, err, engine.Input_Error.None)
	id := e.particle_sets.input[0]
	engine.set_particle(&e, id, visible = true)
	engine.frame_build(&e)
	visual := engine.get_visual(&e, engine.Particle_Id(id))
	// Equal text from a distinct allocation is still an unchanged setting.
	visual.symbol = strings.clone(visual.symbol)
	engine.set_particle(&e, id)
	engine.set_particle(
		&e,
		id,
		coord = e.particles.current_coord[id],
		visible = true,
		layer = 0,
		visual = visual,
	)
	// Separate setter calls preserve omitted settings.
	engine.set_particle(&e, id, coord = engine.Coord{2, 1})
	engine.set_particle(&e, id, layer = 5)
	visual.symbol = "B"
	visual.fg = engine.Color{1, 2, 3}
	engine.set_particle(&e, id, visual = visual)
	testing.expect_value(t, e.particles.layer[id], 5)
	testing.expect_value(t, e.particles.is_visible[id], true)
	engine.frame_build(&e)
	testing.expect_value(t, draw_at(&e, 0), i32(-1))
	testing.expect_value(t, draw_at(&e, 1), i32(id))
	// Clearing a nullable color is an actual visual update.
	visual.fg = nil
	engine.set_particle(&e, id, visual = visual)
	engine.frame_build(&e)
	testing.expect(t, len(engine.frame_bytes(&e)) > 0)
	engine.set_particle(&e, id, visible = false)
	engine.frame_build(&e)
	testing.expect_value(t, draw_at(&e, 1), i32(-1))
}

@(test)
frame_composition_reveals_occluded_visual_changes :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 1, 1
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("A", cfg, context.allocator)
	testing.expect_value(t, err, engine.Input_Error.None)
	back := e.particle_sets.input[0]
	front := engine.add_particle(&e, "B", {1, 1})
	engine.set_particle(&e, back, visible = true)
	engine.set_particle(&e, front, visible = true, layer = 1)
	engine.frame_build(&e)
	testing.expect_value(t, string(engine.frame_bytes(&e)), "B")
	visual := engine.get_visual(&e, engine.Particle_Id(back))
	visual.symbol = "Z"
	engine.set_particle(&e, back, visual = visual)
	engine.frame_build(&e)
	expect_visible_draws(t, &e)
	engine.set_particle(&e, front, visible = false)
	engine.frame_build(&e)
	testing.expect_value(t, string(engine.frame_bytes(&e)), "Z")
	// A hidden selection must not discard another particle's visual update.
	engine.frame_build(&e, []engine.Particle_Id{front})
	visual.symbol = "Y"
	engine.set_particle(&e, back, visual = visual)
	engine.frame_build(&e)
	testing.expect_value(t, string(engine.frame_bytes(&e)), "Y")
}

@(test)
frame_composition_character_growth_is_amortized :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, mem.dynamic_arena_allocator(&arena))
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 1, 1
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("A", cfg, context.allocator)
	testing.expect_value(t, err, engine.Input_Error.None)
	allocations := track.total_allocation_count
	for _ in 0 ..< 8192 do engine.add_particle(&e, "X", {1, 1})
	// Exact-capacity reservation per added character caused quadratic arena
	// growth. Thousands of additions should need only geometric pool growth.
	testing.expect(t, track.total_allocation_count - allocations < 200)
	engine.frame_build(&e)
	allocations = track.total_allocation_count
	for id in 0 ..< len(e.particles) {
		engine.set_particle(&e, engine.Particle_Id(id), visible = true)
	}
	engine.frame_build(&e)
	testing.expect_value(t, track.total_allocation_count, allocations)
}
