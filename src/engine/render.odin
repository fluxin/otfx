package engine

import "base:intrinsics"
import "core:container/bit_array"
import "core:sort"
import "core:time"

// Cell ownership, dirty tracking, and retained row construction.

// Numeric order is layer first, then particle ID; both are checked before packing.
Render_Key :: bit_field u64 {
	id:    u32 | 32,
	layer: u32 | 32,
}

// Flat 12-byte index-linked node indexed directly by Particle_Id.
// Index links survive [dynamic]Render_Node growth without pointer indirection.
Render_Node :: struct {
	prev, next: Particle_Id,
	layer:      u32,
}
#assert(size_of(Render_Node) == 12)

// Compact 16-byte cell (four cells per 64-byte cache line).
Render_Cell :: struct {
	head, tail, top: Particle_Id,
	unordered:       bool,
	needs_resolve:   bool,
	unit_width:      bool, // winning glyph advances terminal cursor by 1 column
	length:          u8, // encoded bytes at the front of the cell's slot
}
#assert(size_of(Render_Cell) == 16)

render_node_key :: #force_inline proc(id: Particle_Id, layer: u32) -> Render_Key {
	return Render_Key{id = u32(id), layer = layer}
}

// Prepare once after engine/effect build, and again only if playback adds IDs.
render_prepare :: proc(e: ^Engine) {
	old_len := len(e.render_nodes)
	if old_len == len(e.particles) do return
	reserve(&e.render_keys, cap(e.particles))
	resize(&e.render_nodes, len(e.particles))
	#no_bounds_check for i in old_len ..< len(e.render_nodes) {
		e.render_nodes[i] = {prev = NO_PARTICLE, next = NO_PARTICLE}
	}
}

@(private)
cell_push_back :: #force_inline proc(e: ^Engine, cell: ^Render_Cell, id: Particle_Id) #no_bounds_check {
	node := &e.render_nodes[id]
	tail := cell.tail
	node.prev = tail
	node.next = NO_PARTICLE
	if tail != NO_PARTICLE {
		e.render_nodes[tail].next = id
	} else {
		cell.head = id
	}
	cell.tail = id
}

@(private)
cell_unlink :: #force_inline proc(e: ^Engine, cell: ^Render_Cell, id: Particle_Id) #no_bounds_check {
	node := &e.render_nodes[id]
	prev, next := node.prev, node.next
	if prev != NO_PARTICLE {
		e.render_nodes[prev].next = next
	} else {
		cell.head = next
	}
	if next != NO_PARTICLE {
		e.render_nodes[next].prev = prev
	} else {
		cell.tail = prev
	}
	node.prev, node.next = NO_PARTICLE, NO_PARTICLE
}

Render_Row :: struct {
	cells: []Render_Cell, // borrowed from the cell grid
}

// Accumulate change kinds; queue each ID once. Published placement lives in its node.
queue_particle :: #force_inline proc(e: ^Engine, id: Particle_Id, change: Particle_Flag) #no_bounds_check {
	flags := e.particles.flags[id]
	e.particles.flags[id] = flags + {change, .Update_Queued}
	if .Update_Queued in flags do return
	append(&e.updates, id)
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

// Ascending set bits of a bit_array iterator, with the traversal inlined;
// bit_array.iterate_by_set calls a helper for every bit.
next_set_bit :: #force_inline proc(it: ^bit_array.Bit_Array_Iterator) -> (index: int, ok: bool) #no_bounds_check {
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

// A known node unlinks directly, even when it is covered and the cell unordered.
cell_remove :: proc(e: ^Engine, id: Particle_Id) #no_bounds_check {
	index := e.particles.cell[id]
	cell := &e.cells[index]
	cell_unlink(e, cell, id)
	e.particles.cell[id] = -1
	if cell.top != id do return
	cell.top = NO_PARTICLE
	mark_cell_dirty(e, index)
	if cell.head == NO_PARTICLE {
		cell.unordered = false
	} else if cell.unordered {
		cell.needs_resolve = true
		append(&e.resolve_cells, index)
	} else {
		cell.top = cell.tail
	}
}

// This cell lost its winner. Sort its final live membership once, after all
// movement/layer updates. Reconnect stable nodes without copying node storage.
cell_resolve :: proc(e: ^Engine, index: int) #no_bounds_check {
	cell := &e.cells[index]
	clear(&e.render_keys)
	for id := cell.head; id != NO_PARTICLE; id = e.render_nodes[id].next {
		append(&e.render_keys, render_node_key(id, e.render_nodes[id].layer))
	}
	if cell.unordered do sort.quick_sort(transmute([]u64)e.render_keys[:])
	cell.head, cell.tail = NO_PARTICLE, NO_PARTICLE
	for key in e.render_keys {
		cell_push_back(e, cell, Particle_Id(key.id))
	}
	cell.top = cell.tail
	cell.unordered = false
	cell.needs_resolve = false
}

cell_insert :: proc(e: ^Engine, index: int, id: Particle_Id) #no_bounds_check {
	cell := &e.cells[index]
	layer := e.particles.layer[id]
	assert(layer >= 0 && layer < max(int), "layer must be a nonnegative array index")
	assert(u64(layer) <= u64(max(u32)), "layer exceeds 32-bit render key")
	node_layer := u32(layer)
	e.render_nodes[id].layer = node_layer
	node_key := transmute(u64)render_node_key(id, node_layer)
	if tail := cell.tail; tail != NO_PARTICLE {
		if transmute(u64)render_node_key(tail, e.render_nodes[tail].layer) > node_key {
			cell.unordered = true
		}
	}
	cell_push_back(e, cell, id)
	e.particles.cell[id] = index
	if cell.needs_resolve do return
	if cell.top == NO_PARTICLE ||
	   node_key > transmute(u64)render_node_key(cell.top, e.render_nodes[cell.top].layer) {
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

// Membership changes unlink/append directly. Resolve unordered winners once
// after the queue, before encoding visible cell bytes.
compose_frame :: proc(e: ^Engine) {
	render_prepare(e)
	// Queue insertion accesses the particle with checks on; IDs are never removed.
	// Published cells come from cell_index, and all SoA columns share one length.
	#no_bounds_check for id in e.updates {
		changes := e.particles.flags[id]
		e.particles.flags[id] -= {.Update_Queued, .Placement_Changed, .Content_Changed}
		when FRAME_STATS_ENABLED {e.stats.candidate_visits += 1}
		cell := e.particles.cell[id]
		if .Placement_Changed in changes {
			previous_cell := cell
			cell = cell_index(e, e.particles.current_coord[id]) if .Visible in changes else -1
			if previous_cell >= 0 &&
			   (cell != previous_cell ||
					   e.particles.layer[id] != int(e.render_nodes[id].layer)) {
				cell_remove(e, id)
			}
			if cell >= 0 && e.particles.cell[id] < 0 {
				cell_insert(e, cell, id)
			}
		}
		if cell >= 0 && .Content_Changed in changes && e.cells[cell].top == id do mark_cell_dirty(e, cell)
	}
	for cell in e.resolve_cells do cell_resolve(e, cell)
	clear(&e.resolve_cells)
	clear(&e.updates)
}

// Encode the winning glyph and appearance directly into the cell's slot.
patch_cell :: proc(e: ^Engine, index: int) #no_bounds_check {
	cell, slot := &e.cells[index], &e.slots[index]
	if id := cell.top; id != NO_PARTICLE {
		cell.length = u8(encode_particle(e, id, slot[:]))
		cell.unit_width = rune_columns(e.particles.symbol[id]) == 1
	} else {
		// A space erases the departed glyph and advances the cursor.
		slot[0] = ' '
		cell.length = 1
		cell.unit_width = true
	}
	when FRAME_STATS_ENABLED {
		e.stats.patched_cells += 1
		e.stats.cell_bytes_written += int(cell.length)
	}
}

frame_build :: proc(e: ^Engine) #no_bounds_check {
	when FRAME_STATS_ENABLED {e.stats.clock = time.tick_now()}
	compose_frame(e)
	when FRAME_STATS_ENABLED {stats_composed(e)}
	it := bit_array.make_iterator(&e.dirty_cells)
	for cell, ok := next_set_bit(&it); ok; cell, ok = next_set_bit(&it) {
		// dirty_cells has exactly len(cells) bits; only clipped/published cells are marked.
		patch_cell(e, cell)
	}
	e.dirty_cells, e.emit_cells = e.emit_cells, e.dirty_cells
	bit_array.clear(&e.dirty_cells)
	when FRAME_STATS_ENABLED {e.stats.emit += time.tick_diff(e.stats.clock, time.tick_now())}
}
