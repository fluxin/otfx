package engine

import "base:intrinsics"
import "core:container/bit_array"
import "core:slice"
import "core:time"

// Cell ownership, dirty tracking, and retained row construction.

@(rodata)
Blank_Cell: [51]byte = {
	0 = ' ',
}

// Numeric order is layer first, then particle ID; both are checked before packing.
Render_Key :: bit_field u64 {
	id:    u32 | 32,
	layer: u32 | 32,
}

Render_Cell :: struct {
	stack: [dynamic]Render_Key, // ascending (layer, particle ID)
	top:   Particle_Id, // NO_PARTICLE when the cell has no occupant
	bytes: []byte, // borrowed fixed-width slot in canvas_bytes
}

@(private = "file")
render_key_compare :: #force_inline proc(a, b: Render_Key) -> slice.Ordering {
	return slice.cmp(transmute(u64)a, transmute(u64)b)
}

Render_Row :: struct {
	cells: []Render_Cell, // borrowed from the cell grid
	bytes: []byte, // borrowed from the fixed-slot byte grid
}

Particle_Update :: struct {
	id:             Particle_Id,
	previous_layer: int,
}

// Accumulate change kinds; retain the published layer before its first edit.
queue_particle :: #force_inline proc(e: ^Engine, id: Particle_Id, change: Particle_Flag) {
	flags := e.particles[id].flags
	e.particles[id].flags = flags + {change, .Update_Queued}
	if .Update_Queued in flags do return
	append(&e.updates, Particle_Update{id, e.particles[id].layer})
}

frame :: proc(e: ^Engine) {
	enforce_framerate(e)
	frame_build(e)
}

mark_cell_dirty :: #force_inline proc(e: ^Engine, cell: int) {
	// engine_make allocates len(cells) bits at bias zero. All callers use
	// clipped or previously published cell indices; no resize/length update is needed.
	bit_array.unsafe_set(&e.dirty_cells, cell)
}

// Native iterator state and ascending order, with the traversal itself inlined.
// Inlining bit_array.iterate_by_set alone leaves its private helper as a call.
@(private)
next_dirty_bit :: #force_inline proc(it: ^bit_array.Bit_Array_Iterator) -> (index: int, ok: bool) {
	for it.word_idx < len(it.array.bits) {
		word := it.array.bits[it.word_idx] >> it.bit_idx
		if word == 0 {
			it.word_idx += 1
			it.bit_idx = 0
			continue
		}
		it.bit_idx += uint(intrinsics.count_trailing_zeros(word))
		index = it.word_idx * 64 + int(it.bit_idx) + it.array.bias
		it.bit_idx += 1
		if it.bit_idx == 64 {
			it.word_idx += 1
			it.bit_idx = 0
		}
		return index, index < it.array.length + it.array.bias
	}
	return 0, false
}

// compose_frame supplies a queued, live particle with published cell membership.
// The stack contains its retained key; a top member implies a nonempty stack.
cell_remove :: proc(e: ^Engine, id: Particle_Id, layer: int) #no_bounds_check {
	index := e.particles[id].cell
	cell := &e.cells[index]
	if cell.top == id {
		pop(&cell.stack)
		cell.top = NO_PARTICLE
		if len(cell.stack) > 0 do cell.top = Particle_Id(cell.stack[len(cell.stack) - 1].id)
		mark_cell_dirty(e, index)
	} else {
		slot := 0
		if cell.stack[0].id != u32(id) {
			key := Render_Key {
				id    = u32(id),
				layer = u32(layer),
			}
			found: bool
			slot, found = slice.binary_search_by(cell.stack[:], key, render_key_compare)
			assert(found)
		}
		ordered_remove(&cell.stack, slot)
	}
	e.particles[id].cell = -1
}

// compose_frame supplies a live particle and a nonnegative cell_index result.
// The empty-stack branch and binary-search insertion point bound stack accesses.
cell_insert :: proc(e: ^Engine, index: int, id: Particle_Id) #no_bounds_check {
	cell := &e.cells[index]
	layer := e.particles[id].layer
	assert(layer >= 0 && layer < max(int), "layer must be a nonnegative array index")
	assert(u64(layer) <= u64(max(u32)), "layer exceeds 32-bit render key")
	key := Render_Key {
		id    = u32(id),
		layer = u32(layer),
	}
	if len(cell.stack) == 0 || render_key_compare(cell.stack[len(cell.stack) - 1], key) == .Less {
		append(&cell.stack, key)
		cell.top = id
		mark_cell_dirty(e, index)
	} else {
		slot := 0
		if render_key_compare(key, cell.stack[0]) != .Less {
			found: bool
			slot, found = slice.binary_search_by(cell.stack[:], key, render_key_compare)
			assert(!found)
		}
		// inject_at resizes exactly; retain geometric growth for interior arrivals.
		if len(cell.stack) == cap(cell.stack) do reserve(&cell.stack, 2 * cap(cell.stack))
		inject_at(&cell.stack, slot, key)
	}
	e.particles[id].cell = index
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

// Each stack retains its published keys, so remove and insert one particle at
// a time. Cell bytes are patched only after every queued update is applied.
compose_frame :: proc(e: ^Engine) -> (width, height: int) {
	width, height = max(e.layout.visible_right, 0), max(e.layout.visible_top, 0)
	// Queue insertion accesses the particle with checks on; IDs are never removed.
	// Published cells come from cell_index, and all SoA columns share one length.
	#no_bounds_check for update in e.updates {
		id := update.id
		changes := e.particles[id].flags
		e.particles[id].flags -= {.Update_Queued, .Placement_Changed, .Content_Changed}
		when FRAME_STATS_ENABLED {e.stats.candidate_visits += 1}
		cell := e.particles[id].cell
		if .Placement_Changed in changes {
			previous_cell := cell
			cell = cell_index(e, e.particles[id].current_coord) if .Visible in changes else -1
			if previous_cell >= 0 &&
			   (cell != previous_cell || e.particles[id].layer != update.previous_layer) {
				cell_remove(e, id, update.previous_layer)
			}
			if cell >= 0 && e.particles[id].cell < 0 {
				cell_insert(e, cell, id)
			}
		}
		if cell >= 0 && .Content_Changed in changes && e.cells[cell].top == id do mark_cell_dirty(e, cell)
	}
	clear(&e.updates)
	return
}

// Encode the winning glyph and appearance directly into its fixed cell slot.
patch_cell :: proc(e: ^Engine, cell: ^Render_Cell) {
	bytes := cell.bytes
	if id := cell.top; id != NO_PARTICLE {
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
	for cell, ok := next_dirty_bit(&it); ok; cell, ok = next_dirty_bit(&it) {
		// dirty_cells has exactly len(cells) bits; only clipped/published cells are marked.
		#no_bounds_check {patch_cell(e, &e.cells[cell])}
		// Nonempty dirty_cells implies positive width; this quotient is a valid row.
		bit_array.unsafe_set(&e.dirty_rows, cell / e.layout.visible_right)
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
		for i, ok := next_dirty_bit(&rows); ok; i, ok = next_dirty_bit(&rows) {
			count += int(i != cursor) + int(len(e.rows[i].bytes) != 0)
			e.stats.output_bytes += len(row_move(move[:], i - cursor)) + len(e.rows[i].bytes)
			cursor = i
		}
		e.stats.parts += count
		e.stats.max_parts = max(e.stats.max_parts, count)
	}
}
