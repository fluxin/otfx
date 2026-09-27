package regression

import "../src/engine"
import "core:container/bit_array"
import "core:container/intrusive/list"
import "core:container/xar"
import "core:mem"
import "core:testing"

// Independently validate links, membership, published keys, and visible winner.
expect_published_cells :: proc(t: ^testing.T, e: ^engine.Engine) {
	seen := make([]bool, len(e.particles))
	defer delete(seen)
	for cell, index in e.cells {
		previous: ^list.Node
		previous_key: u64
		best: u64
		expected_top := engine.NO_PARTICLE
		count := 0
		it := list.iterator_head(cell.occupants, engine.Render_Node, "link")
		for node in list.iterate_next(&it) {
			count += 1
			if count > len(e.particles) {testing.expect(t, false, "cell list cycle"); break}
			id := engine.Particle_Id(node.key.id)
			testing.expect(t, !seen[id])
			seen[id] = true
			testing.expect_value(t, e.particles[id].cell, index)
			testing.expect_value(t, e.particles[id].layer, int(node.key.layer))
			testing.expect_value(t, node, xar.get_ptr(&e.render_nodes, id))
			testing.expect_value(t, node.link.prev, previous)
			if previous != nil && !cell.unordered do testing.expect(t, previous_key < transmute(u64)node.key)
			if expected_top == engine.NO_PARTICLE || transmute(u64)node.key > best {
				best = transmute(u64)node.key
				expected_top = id
			}
			previous = &node.link
			previous_key = transmute(u64)node.key
		}
		testing.expect_value(t, previous, cell.occupants.tail)
		testing.expect_value(t, cell.top, expected_top)
		testing.expect(t, !cell.needs_resolve)
	}
	for particle, id in e.particles do testing.expect_value(t, seen[id], particle.cell >= 0)
}

cell_keys :: proc(cell: engine.Render_Cell) -> []engine.Render_Key {
	keys := make([dynamic]engine.Render_Key, context.temp_allocator)
	it := list.iterator_head(cell.occupants, engine.Render_Node, "link")
	for node in list.iterate_next(&it) do append(&keys, node.key)
	return keys[:]
}

cell_layer_count :: proc(cell: engine.Render_Cell, layer: int) -> int {
	count := 0
	for entry in cell_keys(cell) do count += int(int(entry.layer) == layer)
	return count
}

// Independent full-paint oracle: no retained membership or dirty state.
raster_expected :: proc(e: ^engine.Engine, out: []i32) {
	for &cell in out do cell = -1
	for id in 0 ..< len(e.particles) {
		if (.Visible not_in e.particles.flags[id]) do continue
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
	// Exercise bitmap tails, rows sharing a word, and particle growth.
	// Overlaps include different and equal layers.
	for width in ([]int{1, 7, 63, 64, 65}) {
		cfg := engine.config_default()
		cfg.canvas_width, cfg.canvas_height = width, 3
		cfg.ignore_terminal_dimensions = true
		e, err := engine.engine_make("ABC\nD", cfg)
		testing.expect_value(t, err, engine.Input_Error.None)
		shared := engine.prepare_appearance(&e, engine.Appearance{})
		expected := make([]i32, width * 3)
		for tick in 0 ..< 90 {
			if tick == 30 || tick == 60 {
				for _ in 0 ..< 65 do engine.add_particle(&e, 'X', shared, {1, 1})
			}
			for id in 0 ..< len(e.particles) {
				// Include clipping and crowded cells; leave positions unchanged
				// on alternate ticks to exercise independent layer/appearance changes.
				visible :=
					(id + tick) % 5 != 0 &&
					(tick % 4 == 0 || (tick % 7 != 0 && (id + tick) % 3 != 0))
				layer := (id + tick / 3) % 4
				position := engine.Coord{(id * 7 + tick / 2) % (width + 2), (id + tick / 4) % 5}
				if tick % 2 == 0 {
					engine.set_particle(
						&e,
						engine.Particle_Id(id),
						coord = position,
						visible = visible,
						layer = layer,
					)
				} else {
					engine.set_particle(&e, engine.Particle_Id(id), engine.Visible(visible))
					engine.set_particle(&e, engine.Particle_Id(id), engine.Layer(layer))
					engine.set_particle(&e, engine.Particle_Id(id), position)
				}
				engine.set_symbol(&e, engine.Particle_Id(id), 'X' if (id + tick) % 2 == 0 else 'Y')
				engine.set_foreground(&e, engine.Particle_Id(id), engine.Color{u8(tick), 100, 200})
			}
			engine.compose_frame(&e)
			expect_published_cells(t, &e)
			raster_expected(&e, expected)
			engine.frame_build(&e)
			for cell, index in expected do testing.expect_value(t, draw_at(&e, index), cell)
			// Rebuilding preserves the same visible appearance.
			engine.frame_build(&e)
			expect_visible_draws(t, &e)
		}
	}
}

@(test)
cell_layers_reuse_storage_and_reveal_lower_occupants :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 1, 1
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("A", cfg)
	testing.expect_value(t, err, engine.Input_Error.None)
	shared := engine.prepare_appearance(&e, engine.Appearance{})
	ids: [32]engine.Particle_Id
	for &id, i in ids {
		id = engine.add_particle(&e, 'X', shared, {1, 1})
		engine.set_particle(
			&e,
			id,
			visible = true,
			layer = (i * 7) % 9 + 1,
			coord = e.particles[id].current_coord,
		)
	}
	engine.frame_build(&e)
	storage :: proc(e: ^engine.Engine) -> (count, capacity: int) {
		count, capacity = len(cell_keys(e.cells[0])), xar.cap(e.render_nodes) + cap(e.render_keys)
		return
	}
	slots, _ := storage(&e)
	capacity := 0
	expected: [1]i32
	for tick in 0 ..< 256 {
		id := ids[(tick * 13) % len(ids)]
		engine.set_particle(&e, id, engine.Visible(false))
		engine.frame_build(&e)
		expect_published_cells(t, &e)
		raster_expected(&e, expected[:])
		testing.expect_value(t, draw_at(&e, 0), expected[0])
		engine.set_particle(&e, id, engine.Layer(((tick % 128) * 5) % 11))
		engine.set_particle(&e, id, engine.Visible(true))
		engine.frame_build(&e)
		expect_published_cells(t, &e)
		raster_expected(&e, expected[:])
		testing.expect_value(t, draw_at(&e, 0), expected[0])
		count, current_capacity := storage(&e)
		testing.expect_value(t, count, slots)
		// Repeat the same layer transitions after warming every bucket.
		if tick == 127 do capacity = current_capacity
		if tick >= 128 do testing.expect_value(t, current_capacity, capacity)
	}
	for id in ids do engine.set_particle(&e, id, engine.Visible(false))
	engine.frame_build(&e)
	testing.expect_value(t, draw_at(&e, 0), i32(-1))
	for i := len(ids) - 1; i >= 0; i -= 1 {
		engine.set_particle(&e, ids[i], engine.Visible(true))
		engine.frame_build(&e)
		raster_expected(&e, expected[:])
		testing.expect_value(t, draw_at(&e, 0), expected[0])
	}
	count, current_capacity := storage(&e)
	testing.expect_value(t, count, slots)
	testing.expect_value(t, current_capacity, capacity)
}

@(test)
flat_cell_stack_reuses_storage_across_layers :: proc(t: ^testing.T) {
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
	e, err := engine.engine_make("A", cfg)
	testing.expect_value(t, err, engine.Input_Error.None)
	id := e.particle_sets.input[0]
	engine.set_particle(&e, id, engine.Visible(true))
	engine.frame_build(&e)
	// Changing layers reuses the same cell stack even across large layer values.
	for layer in 0 ..= 128 {
		engine.set_particle(&e, id, engine.Layer(layer))
		engine.frame_build(&e)
		testing.expect_value(t, draw_at(&e, 0), i32(id))
	}
	allocations := track.total_allocation_count
	for layer := 128; layer >= 0; layer -= 1 {
		engine.set_particle(&e, id, engine.Layer(layer))
		engine.frame_build(&e)
		testing.expect_value(t, draw_at(&e, 0), i32(id))
	}
	testing.expect_value(t, len(cell_keys(e.cells[0])), 1)
	engine.set_layer(&e, id, engine.Layer(max(u32)))
	engine.frame_build(&e)
	testing.expect_value(t, cell_keys(e.cells[0])[0].layer, max(u32))
	testing.expect_value(t, track.total_allocation_count, allocations)
	expect_published_cells(t, &e)
}

@(test)
layer_setter_rejects_negative_index :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 1, 1
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("A", cfg)
	testing.expect_value(t, err, engine.Input_Error.None)
	testing.expect_assert(t, "layer must be a nonnegative array index")
	engine.set_particle(&e, e.particle_sets.input[0], engine.Layer(-1))
}

@(test)
placement_setter_rejects_negative_index :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 1, 1
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("A", cfg)
	testing.expect_value(t, err, engine.Input_Error.None)
	testing.expect_assert(t, "layer must be a nonnegative array index")
	engine.set_particle(&e, e.particle_sets.input[0], coord = {1, 1}, visible = false, layer = -1)
}

@(test)
frame_composition_keeps_pending_appearance_changes :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 65, 2
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("A", cfg)
	testing.expect_value(t, err, engine.Input_Error.None)
	id := e.particle_sets.input[0]
	e.particles.flags[id] += {.Visible}
	e.particles.current_coord[id] = {65, 2}
	engine.frame_build(&e)
	expect_frame_cell(t, &e, 64, 0, 'A', engine.Appearance{})
	// Update without emission, then move again. Only the latest position is
	// drawn, but the last emitted position must still be erased.
	engine.set_particle(&e, id, engine.Coord{1, 1})
	engine.compose_frame(&e)
	engine.set_particle(&e, id, engine.Coord{2, 1})
	engine.set_symbol(&e, engine.Particle_Id(id), 'B')
	engine.frame_build(&e)
	expect_frame_cell(t, &e, 64, 0, ' ', engine.Appearance{})
	expect_frame_cell(t, &e, 1, 1, 'B', engine.Appearance{})
	engine.frame_build(&e)
	expect_visible_draws(t, &e)
}

@(test)
particle_setters_preserve_other_fields :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 3, 1
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("A", cfg)
	testing.expect_value(t, err, engine.Input_Error.None)
	id := e.particle_sets.input[0]
	engine.set_particle(&e, id, engine.Visible(true))
	engine.frame_build(&e)
	appearance := engine.get_appearance(&e, engine.Particle_Id(id))
	// Reapplying an equal appearance is still an unchanged setting.
	engine.set_particle(&e, id, coord = e.particles.current_coord[id], visible = true, layer = 0)
	engine.set_appearance(&e, id, appearance)
	// Single-field setter calls preserve the other fields.
	engine.set_particle(&e, id, engine.Coord{2, 1})
	engine.set_particle(&e, id, engine.Layer(5))
	engine.set_symbol(&e, id, 'B')
	appearance.colors.fg = engine.Color{1, 2, 3}
	engine.set_appearance(&e, id, appearance)
	engine.compose_frame(&e)
	testing.expect_value(t, e.particles.layer[id], 5)
	testing.expect_value(t, (.Visible in e.particles.flags[id]), true)
	engine.frame_build(&e)
	testing.expect_value(t, draw_at(&e, 0), i32(-1))
	testing.expect_value(t, draw_at(&e, 1), i32(id))
	// Clearing a nullable color is an actual appearance update.
	appearance.colors.fg = nil
	engine.set_appearance(&e, id, appearance)
	engine.frame_build(&e)
	testing.expect(t, len(frame_without_padding(&e)) > 0)
	engine.set_particle(&e, id, engine.Visible(false))
	engine.frame_build(&e)
	testing.expect_value(t, draw_at(&e, 1), i32(-1))
}

@(test)
frame_composition_reveals_occluded_appearance_changes :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 1, 1
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("A", cfg)
	testing.expect_value(t, err, engine.Input_Error.None)
	back := e.particle_sets.input[0]
	front := engine.add_particle(
		&e,
		'B',
		engine.prepare_appearance(&e, engine.Appearance{}),
		{1, 1},
	)
	engine.set_particle(&e, back, engine.Visible(true))
	engine.set_particle(
		&e,
		front,
		visible = true,
		layer = 1,
		coord = e.particles[front].current_coord,
	)
	engine.frame_build(&e)
	testing.expect_value(t, string(frame_without_padding(&e)), "B")
	appearance := engine.get_appearance(&e, engine.Particle_Id(back))
	engine.set_symbol(&e, back, 'Z')
	engine.set_appearance(&e, back, appearance)
	engine.frame_build(&e)
	expect_visible_draws(t, &e)
	engine.set_particle(&e, front, engine.Visible(false))
	engine.frame_build(&e)
	testing.expect_value(t, string(frame_without_padding(&e)), "Z")
	// A hidden particle retains appearance updates until it re-enters.
	engine.set_particle(&e, back, engine.Visible(false))
	engine.frame_build(&e)
	engine.set_symbol(&e, back, 'Y')
	engine.set_appearance(&e, back, appearance)
	engine.set_particle(&e, back, engine.Visible(true))
	engine.frame_build(&e)
	testing.expect_value(t, string(frame_without_padding(&e)), "Y")
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
	e, err := engine.engine_make("A", cfg)
	testing.expect_value(t, err, engine.Input_Error.None)
	shared := engine.prepare_appearance(&e, engine.Appearance{})
	allocations := track.total_allocation_count
	for _ in 0 ..< 8192 do engine.add_particle(&e, 'X', shared, {1, 1})
	// Exact-capacity reservation per added character caused quadratic arena
	// growth. Thousands of additions should need only geometric pool growth.
	testing.expect(t, track.total_allocation_count - allocations < 200)
	engine.frame_build(&e)
	allocations = track.total_allocation_count
	for id in 0 ..< len(e.particles) {
		engine.set_particle(&e, engine.Particle_Id(id), engine.Visible(true))
	}
	engine.frame_build(&e)
	testing.expect_value(t, track.total_allocation_count, allocations)
}

@(test)
frame_composition_clips_signed_extremes_and_empty_viewport :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 3, 3
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("A", cfg)
	testing.expect_value(t, err, engine.Input_Error.None)
	e.layout.row_offset, e.layout.col_offset = 7, -11
	id := e.particle_sets.input[0]
	expected: [9]i32
	for p in ([]engine.Coord{{1, 1}, {3, 3}, {0, 1}, {4, 1}, {1, 0}, {1, 4}, {min(int), 1}, {max(int), 1}, {1, min(int)}, {1, max(int)}}) {
		engine.set_particle(
			&e,
			id,
			visible = true,
			coord = engine.Coord{p.column - e.layout.col_offset, p.row - e.layout.row_offset},
			layer = e.particles[id].layer,
		)
		engine.compose_frame(&e)
		raster_expected(&e, expected[:])
		engine.frame_build(&e)
		for cell, index in expected do testing.expect_value(t, draw_at(&e, index), cell)
	}
	// An inverted interval is empty; unsigned interval widths must not admit it.
	e.layout.visible_left = 4
	for i in 0 ..< len(e.rows) do bit_array.set(&e.dirty_rows, i)
	engine.set_particle(&e, id, engine.Coord{2 - e.layout.col_offset, 2 - e.layout.row_offset})
	engine.frame_build(&e)
	for cell in e.cells do testing.expect(t, cell.top == engine.NO_PARTICLE)
}

@(test)
render_key_orders_full_u32_fields :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(engine.Render_Key), 8)
	low := engine.Render_Key {
		id    = max(u32),
		layer = 0,
	}
	high := engine.Render_Key {
		id    = 0,
		layer = 1,
	}
	last := engine.Render_Key {
		id    = max(u32),
		layer = max(u32),
	}
	testing.expect(t, transmute(u64)low < transmute(u64)high)
	testing.expect_value(t, transmute(u64)last, max(u64))
}

@(test)
layer_setter_rejects_unrepresentable_key :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	e, err := engine.engine_make("A", engine.config_default())
	testing.expect_value(t, err, engine.Input_Error.None)
	testing.expect_assert(t, "layer exceeds 32-bit render key")
	engine.set_layer(&e, e.particle_sets.input[0], engine.Layer(u64(1) << 32))
}

@(test)
placement_setter_rejects_unrepresentable_key :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	e, err := engine.engine_make("A", engine.config_default())
	testing.expect_value(t, err, engine.Input_Error.None)
	testing.expect_assert(t, "layer exceeds 32-bit render key")
	engine.set_placement(&e, e.particle_sets.input[0], {1, 1}, true, int(u64(1) << 32))
}

@(test)
particle_batch_rejects_unrepresentable_count :: proc(t: ^testing.T) {
	e: engine.Engine
	testing.expect_assert(t, "particle count exceeds 32-bit IDs")
	engine.particle_batch(&e, int(u64(1) << 32))
}

@(test)
particle_id_zero_is_distinct_from_an_empty_cell :: proc(t: ^testing.T) {
	#assert(size_of(engine.Particle_Id) == 4)
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 1, 1
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("A", cfg)
	testing.expect_value(t, err, engine.Input_Error.None)
	testing.expect(t, e.cells[0].top == engine.NO_PARTICLE)
	id := e.particle_sets.input[0]
	testing.expect_value(t, id, engine.Particle_Id(0))
	engine.set_visible(&e, id, true)
	engine.frame_build(&e)
	winner := e.cells[0].top
	testing.expect(t, winner != engine.NO_PARTICLE)
	testing.expect_value(t, winner, id)
	engine.set_visible(&e, id, false)
	engine.frame_build(&e)
	testing.expect(t, e.cells[0].top == engine.NO_PARTICLE)
	testing.expect_value(t, e.cells[0].bytes[0], u8(' '))
	testing.expect_value(t, engine.NO_PARTICLE, max(engine.Particle_Id))
}

@(test)
particle_constructor_rejects_empty_cell_sentinel :: proc(t: ^testing.T) {
	e: engine.Engine
	testing.expect_assert(t, "particle ID is reserved for an empty cell")
	engine.init_particle(&e, engine.NO_PARTICLE, 'A', 1, {1, 1})
}

@(test)
cell_stack_interior_growth_is_amortized :: proc(t: ^testing.T) {
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
	e, err := engine.engine_make("A", cfg)
	testing.expect_value(t, err, engine.Input_Error.None)
	base := e.particle_sets.input[0]
	engine.set_visible(&e, base, true)
	ids: [512]engine.Particle_Id
	batch := engine.particle_batch(&e, len(ids))
	for &id in ids do id = engine.add_particle(&batch, 'X', e.particles[base].initial_appearance_id, {1, 1})
	engine.frame_build(&e)
	engine.set_visible(&e, ids[len(ids) - 1], true)
	engine.frame_build(&e)
	allocations := track.total_allocation_count
	// Lower IDs arrive beneath the winner, forcing interior insertion as the
	// stack grows. Capacity must not grow by one allocation per new occupant.
	for i := len(ids) - 2; i >= 0; i -= 1 {
		engine.set_visible(&e, ids[i], true)
		engine.frame_build(&e)
	}
	testing.expect(t, track.total_allocation_count - allocations < 16)
	testing.expect_value(t, len(cell_keys(e.cells[0])), len(ids) + 1)
	testing.expect_value(t, e.cells[0].top, ids[len(ids) - 1])
	expect_published_cells(t, &e)
}
