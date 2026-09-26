package engine

import "core:container/bit_array"
import "core:slice"
import "core:time"

// Cell ownership, dirty tracking, and retained row construction.

@(rodata)
Blank_Cell: [51]byte = {
	0 = ' ',
}

Render_Cell :: struct {
	layers: [dynamic][dynamic]Particle_Id, // indexed directly by layer
	top:    Particle_Id,
	bytes:  []byte, // borrowed fixed-width slot in canvas_bytes
}

Render_Row :: struct {
	cells: []Render_Cell, // borrowed from the cell grid
	bytes: []byte, // borrowed from the fixed-slot byte grid
}

Particle_Update :: struct {
	id:             Particle_Id,
	previous_cell:  int,
	previous_layer: int,
}

// Snapshot published placement only on the first edit before the next frame.
queue_particle :: #force_inline proc(e: ^Engine, id: Particle_Id) {
	if .Update_Queued in e.particles[id].flags do return
	cell :=
		cell_index(e, e.particles[id].current_coord) if (.Visible in e.particles[id].flags) else -1
	append(&e.updates, Particle_Update{id, cell, e.particles[id].layer})
	e.particles[id].flags += {.Update_Queued}
}

frame :: proc(e: ^Engine) {
	enforce_framerate(e)
	frame_build(e)
}

mark_cell_dirty :: #force_inline proc(e: ^Engine, cell: int) {
	bit_array.set(&e.dirty_cells, cell)
}

cell_remove :: proc(e: ^Engine, index: int, id: Particle_Id, layer: int) {
	cell := &e.cells[index]
	ids := &cell.layers[layer]
	slot, found := slice.linear_search(ids[:], id)
	assert(found)
	ordered_remove(ids, slot)
	if cell.top != id do return

	// The last nonempty layer supplies the replacement winner.
	top := Particle_Id(-1)
	for layer := len(cell.layers) - 1; layer >= 0; layer -= 1 {
		if len(cell.layers[layer]) == 0 do continue
		for candidate in cell.layers[layer] {
			when FRAME_STATS_ENABLED {e.stats.ownership_visits += 1}
			top = max(top, candidate)
		}
		break
	}
	cell.top = top
	mark_cell_dirty(e, index)
}

cell_insert :: proc(e: ^Engine, index: int, id: Particle_Id) {
	cell := &e.cells[index]
	layer := e.particles[id].layer
	assert(layer >= 0 && layer < max(int), "layer must be a nonnegative array index")
	if layer >= len(cell.layers) do resize(&cell.layers, layer + 1)
	ids := &cell.layers[layer]
	append(ids, id)
	if cell.top < 0 ||
	   layer > e.particles[cell.top].layer ||
	   (layer == e.particles[cell.top].layer && id > cell.top) {
		cell.top = id
		mark_cell_dirty(e, index)
	}
}

cell_index :: #force_inline proc(e: ^Engine, coord: Coord) -> int {
	row, column := coord.row + e.layout.row_offset, coord.column + e.layout.col_offset
	if row < e.layout.visible_bottom ||
	   row > e.layout.visible_top ||
	   column < e.layout.visible_left ||
	   column > e.layout.visible_right {
		return -1
	}
	return (e.layout.visible_top - row) * e.layout.visible_right + column - 1
}

// Remove old memberships before inserting final placements: queued particles'
// current layers may already differ from the layers in the published grid.
compose_frame :: proc(e: ^Engine) -> (width, height: int) {
	width, height = max(e.layout.visible_right, 0), max(e.layout.visible_top, 0)
	for update in e.updates {
		id := update.id
		cell :=
			cell_index(e, e.particles[id].current_coord) if (.Visible in e.particles[id].flags) else -1
		if update.previous_cell >= 0 &&
		   (cell != update.previous_cell || e.particles[id].layer != update.previous_layer) {
			cell_remove(e, update.previous_cell, id, update.previous_layer)
		}
	}
	for update in e.updates {
		id := update.id
		e.particles[id].flags -= {.Update_Queued}
		when FRAME_STATS_ENABLED {e.stats.candidate_visits += 1}
		if (.Visible not_in e.particles[id].flags) do continue
		cell := cell_index(e, e.particles[id].current_coord)
		if cell < 0 do continue
		if cell != update.previous_cell || e.particles[id].layer != update.previous_layer {
			cell_insert(e, cell, id)
		}
		if e.cells[cell].top == id do mark_cell_dirty(e, cell)
	}
	clear(&e.updates)
	return
}

// Encode the winning glyph and appearance directly into its fixed cell slot.
patch_cell :: proc(e: ^Engine, cell: ^Render_Cell) {
	bytes := cell.bytes
	id := cell.top
	if id >= 0 {
		encode_particle(e, id, bytes)
	} else {
		copy(bytes, Blank_Cell[:])
	}
	when FRAME_STATS_ENABLED {
		e.stats.patched_cells += 1
		e.stats.cell_bytes_written += len(bytes)
	}
}

frame_build :: proc(e: ^Engine) {
	when FRAME_STATS_ENABLED {e.stats.clock = time.tick_now()}
	compose_frame(e)
	when FRAME_STATS_ENABLED {stats_composed(e)}
	it := bit_array.make_iterator(&e.dirty_cells)
	for cell, ok := bit_array.iterate_by_set(&it); ok; cell, ok = bit_array.iterate_by_set(&it) {
		patch_cell(e, &e.cells[cell])
		bit_array.set(&e.dirty_rows, cell / e.layout.visible_right)
	}
	bit_array.clear(&e.dirty_cells)
	e.dirty_rows, e.emit_rows = e.emit_rows, e.dirty_rows
	bit_array.clear(&e.dirty_rows)
	when FRAME_STATS_ENABLED {
		e.stats.emit += time.tick_diff(e.stats.clock, time.tick_now())
		stats_rows(e)
		count, cursor := 1, 0
		move: [24]byte
		e.stats.output_bytes += len(Frame_Origin)
		rows := bit_array.make_iterator(&e.emit_rows)
		for i, ok := bit_array.iterate_by_set(&rows); ok; i, ok = bit_array.iterate_by_set(&rows) {
			count += int(i != cursor) + int(len(e.rows[i].bytes) != 0)
			e.stats.output_bytes += len(row_move(move[:], i - cursor)) + len(e.rows[i].bytes)
			cursor = i
		}
		e.stats.parts += count
		e.stats.max_parts = max(e.stats.max_parts, count)
	}
}
