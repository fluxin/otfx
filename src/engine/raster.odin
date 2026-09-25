package engine

import "core:container/bit_array"

// The raster persists between frames. A cell owns an intrusive list of its
// visible candidates; its winner is the maximum (layer, creation index).
// Effects tag characters when writing their renderer-visible state. A bitmap
// deduplicates membership changes across setters until the next raster update.
// Dirty bits cover membership, layer and winning-visual changes, and remain
// pending until emission, including when a tool updates without emitting.
// engine_make/add_character provision storage before these unchecked operations.
raster_mark_dirty :: #force_inline proc(e: ^Engine, cell: int) {
	bit_array.unsafe_set(&e.dirty_cells, cell)
	bit_array.unsafe_set(&e.raster_dirty_cells, cell)
}

// Output-only dirty bit. Membership is unchanged, so the winner cannot move.
raster_mark_output :: #force_inline proc(e: ^Engine, cell: int) {
	bit_array.unsafe_set(&e.dirty_cells, cell)
}

// A visual-only change is already visible to its cell owner. When the character
// owns the winning cell, mark that cell directly; otherwise the change stays
// latent until membership changes expose it. This skips the shared change
// membership scan and winner resolution for color/symbol updates.
raster_mark_visual_change :: #force_inline proc(e: ^Engine, id: int) {
	link := e.chars.render[id].cell
	if link == 0 do return
	cell := int(link - 1)
	if e.render_cells[cell] == i32(id) do raster_mark_output(e, cell)
}

raster_unlink :: #force_inline proc(e: ^Engine, id: int) {
	chars := e.chars[:]
	link := chars.render[id].cell
	if link == 0 do return
	cell := int(link - 1)
	previous, next := chars.render[id].previous, chars.render[id].next
	if previous == 0 {
		e.raster_heads[cell] = next
	} else {
		chars.render[previous - 1].next = next
	}
	if next != 0 do chars.render[next - 1].previous = previous
	chars.render[id].cell = 0
	raster_mark_dirty(e, cell)
}

raster_sync_character :: #force_inline proc(e: ^Engine, id, width: int) {
	chars := e.chars[:]
	cell := EMPTY_CELL
	if chars.is_visible[id] {
		p := chars.current_coord[id]
		row, column := p.row + e.layout.row_offset, p.column + e.layout.col_offset
		if row >= e.layout.visible_bottom &&
		   row <= e.layout.visible_top &&
		   column >= e.layout.visible_left &&
		   column <= e.layout.visible_right {
			cell = i32((row - 1) * width + column - 1)
		}
	}
	if cell + 1 != chars.render[id].cell {
		raster_unlink(e, id)
		if cell != EMPTY_CELL {
			next := e.raster_heads[cell]
			chars.render[id].cell = cell + 1
			chars.render[id].previous = 0
			chars.render[id].next = next
			if next != 0 do chars.render[next - 1].previous = i32(id + 1)
			e.raster_heads[cell] = i32(id + 1)
			raster_mark_dirty(e, int(cell))
		}
	} else if cell != EMPTY_CELL {
		raster_mark_dirty(e, int(cell))
	}
}

// Resolve after all membership changes. Moving many overlapping characters
// therefore revisits their cell once, rather than after every departure.
raster_resolve_dirty :: proc(e: ^Engine) {
	chars := e.chars[:]
	cells := bit_array.make_iterator(&e.raster_dirty_cells)
	for cell in #force_inline bit_array.iterate_by_set(&cells) {
		winner := EMPTY_CELL
		for link := e.raster_heads[cell]; link != 0; link = chars.render[link - 1].next {
			id := link - 1
			if winner == EMPTY_CELL ||
			   chars.layer[id] > chars.layer[winner] ||
			   (chars.layer[id] == chars.layer[winner] && id > winner) {
				winner = id
			}
		}
		e.render_cells[cell] = winner
	}
	bit_array.clear(&e.raster_dirty_cells)
}

// Internal membership changes preserve the encoded appearance cache.
raster_mark_character :: #force_inline proc(e: ^Engine, id: Char_Id) {
	bit_array.unsafe_set(&e.dirty_characters, int(id))
}

// Direct writes may change any render setting. Invalidate derived bytes before
// synchronizing membership; typed setters can invalidate more precisely.
mark_character_dirty :: #force_inline proc(e: ^Engine, id: Char_Id) {
	invalidate_visual_bytes(e, id)
	raster_mark_character(e, id)
}

// Apply any supplied render settings; omitted settings keep their value.
// Compare logical state before tagging so held animation frames do no raster
// work. Several setters before an update still mark only one membership bit.
set_character :: #force_inline proc(
	e: ^Engine,
	id: Char_Id,
	coord: Maybe(Coord) = nil,
	visible: Maybe(bool) = nil,
	layer: Maybe(int) = nil,
	visual: union {
		Visual,
		Visual_Code_Id,
	} = nil,
) {
	changed := false
	if value, ok := coord.?; ok && value != e.chars.current_coord[id] {
		e.chars.current_coord[id] = value
		changed = true
	}
	if value, ok := visible.?; ok && value != e.chars.is_visible[id] {
		e.chars.is_visible[id] = value
		changed = true
	}
	if value, ok := layer.?; ok && value != e.chars.layer[id] {
		e.chars.layer[id] = value
		changed = true
	}
	switch value in visual {
	case Visual:
		set_visual(e, id, value)
	case Visual_Code_Id:
		set_visual(e, id, value)
	}
	if changed do raster_mark_character(e, id)
}

raster_consume_changes :: proc(e: ^Engine, width: int) {
	characters := bit_array.make_iterator(&e.dirty_characters)
	for id in #force_inline bit_array.iterate_by_set(&characters) {
		if e.raster_all || bit_array.unsafe_get(&e.raster_selected, id) {
			raster_sync_character(e, id, width)
		} else {
			raster_unlink(e, id)
		}
	}
	bit_array.clear(&e.dirty_characters)
	raster_resolve_dirty(e)
}

raster_selection_changes :: proc(e: ^Engine, all: bool) {
	for old, word_index in e.raster_selected.bits {
		prior := ~u64(0) if e.raster_all else old
		next := ~u64(0) if all else e.raster_next_selected.bits[word_index]
		changed := prior ~ next
		if word_index == len(e.raster_selected.bits) - 1 && len(e.chars) & 63 != 0 {
			changed &= (u64(1) << uint(len(e.chars) & 63)) - 1
		}
		e.dirty_characters.bits[word_index] |= changed
	}
	e.raster_all = all
}

update_render_cells_all :: proc(e: ^Engine) -> (width, height: int) {
	width, height = max(e.layout.visible_right, 0), max(e.layout.visible_top, 0)
	if !e.raster_all do raster_selection_changes(e, true)
	raster_consume_changes(e, width)
	return
}

update_render_cells_selected :: proc(e: ^Engine, selected: []Char_Id) -> (width, height: int) {
	width, height = max(e.layout.visible_right, 0), max(e.layout.visible_top, 0)
	bit_array.clear(&e.raster_next_selected)
	for id in selected do bit_array.unsafe_set(&e.raster_next_selected, int(id))
	raster_selection_changes(e, false)
	e.raster_selected, e.raster_next_selected = e.raster_next_selected, e.raster_selected
	raster_consume_changes(e, width)
	return
}
