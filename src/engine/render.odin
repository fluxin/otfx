package engine

import "core:container/bit_array"
import "core:slice"
import "core:time"

frame :: proc(e: ^Engine, selected: Maybe([]Particle_Id) = nil) {
	enforce_framerate(e)
	frame_build(e, selected)
	free_all(context.temp_allocator)
}

// Coordinates are bottom-up; renderer rows are top-down.
dirty_row :: #force_inline proc(e: ^Engine, coord: Coord) {
	row := coord.row + e.layout.row_offset
	if row < e.layout.visible_bottom || row > e.layout.visible_top do return
	e.dirty_rows[e.layout.visible_top - row] = true
}

dirty_particle_row :: #force_inline proc(e: ^Engine, id: Particle_Id) {
	if e.particles.is_visible[id] do dirty_row(e, e.particles.current_coord[id])
}

mark_cell_dirty :: #force_inline proc(e: ^Engine, cell: int) {
	if !bit_array.get(&e.dirty_cells, cell) {
		bit_array.set(&e.dirty_cells, cell)
		e.row_changes[cell / e.layout.visible_right] += 1
	}
}

// Appearance changes keep placement intact and publish only the current winner.
dirty_visual :: #force_inline proc(e: ^Engine, id: Particle_Id) {
	if !e.particles[id].is_visible do return
	coord := e.particles[id].current_coord
	row, column := coord.row + e.layout.row_offset, coord.column + e.layout.col_offset
	if row < e.layout.visible_bottom || row > e.layout.visible_top do return
	output_row := e.layout.visible_top - row
	e.dirty_rows[output_row] = true
	if column < e.layout.visible_left || column > e.layout.visible_right do return
	cell := output_row * e.layout.visible_right + column - 1
	if e.frame_particles[cell] != id do return
	visual := e.particles[id].visual_id
	e.frame_visuals[cell] = visual
	if e.row_valid[output_row] && !bit_array.get(&e.dirty_cells, cell) {
		offset := output_row * (e.layout.visible_right + 1) + column - 1
		start, end := e.cell_offsets[offset], e.cell_offsets[offset + 1]
		entry := &e.visuals[visual - 1]
		length := int(entry.packet.length)
		if len(entry.visual.symbol) <= 4 && length == end - start {
			when FRAME_STATS_ENABLED {
				e.stats.patched_cells += 1
				e.stats.packet_bytes_copied += length
			}
			// Styled ASCII: 43-byte prefix, one glyph byte, four-byte reset.
			if length == 48 {
				copy(e.row_bytes[output_row][start:end][:48], entry.packet.bytes[:48])
			} else {
				copy(e.row_bytes[output_row][start:end], entry.packet.bytes[:length])
			}
			return
		}
	}
	mark_cell_dirty(e, cell)
}

// Links and cell coordinates are one-based; zero means unlinked.
cell_publish :: proc(e: ^Engine, cell: int, id: Particle_Id) {
	e.frame_particles[cell] = id
	e.frame_visuals[cell] = NO_VISUAL if id < 0 else e.particles[id].visual_id
	row := cell / e.layout.visible_right
	e.dirty_rows[row] = true
	mark_cell_dirty(e, cell)
}

cell_rewin :: proc(e: ^Engine, cell: int) {
	best := Particle_Id(-1)
	link := e.cell_heads[cell]
	for link != 0 {
		when FRAME_STATS_ENABLED {e.stats.ownership_visits += 1}
		id := link - 1
		if best < 0 ||
		   e.particles[id].layer > e.particles[best].layer ||
		   (e.particles[id].layer == e.particles[best].layer && id > best) {best = id}
		link = e.particles[id].cell_next
	}
	cell_publish(e, cell, best)
}

cell_unlink :: proc(e: ^Engine, id: Particle_Id) {
	cell := e.particles[id].frame_cell - 1
	if cell < 0 do return
	previous, next := e.particles[id].cell_previous, e.particles[id].cell_next
	if previous == 0 {
		e.cell_heads[cell] = next
	} else {
		e.particles[previous - 1].cell_next = next
	}
	if next != 0 do e.particles[next - 1].cell_previous = previous
	e.particles[id].frame_cell = 0
	e.particles[id].cell_previous, e.particles[id].cell_next = 0, 0
	if e.frame_particles[cell] == id do cell_rewin(e, cell)
}

cell_link :: proc(e: ^Engine, id: Particle_Id, cell: int) {
	next := e.cell_heads[cell]
	e.particles[id].frame_cell = cell + 1
	e.particles[id].cell_previous, e.particles[id].cell_next = 0, next
	if next != 0 do e.particles[next - 1].cell_previous = id + 1
	e.cell_heads[cell] = id + 1
	best := e.frame_particles[cell]
	if best < 0 ||
	   e.particles[id].layer > e.particles[best].layer ||
	   (e.particles[id].layer == e.particles[best].layer && id > best) {cell_publish(e, cell, id)}
}

track_particle :: proc(e: ^Engine, id: Particle_Id) {
	cell := -1
	if e.particles[id].is_visible && e.particles[id].frame_selection != .Absent {
		coord := e.particles[id].current_coord
		row, column := coord.row + e.layout.row_offset, coord.column + e.layout.col_offset
		if row >= e.layout.visible_bottom &&
		   row <= e.layout.visible_top &&
		   column >= e.layout.visible_left &&
		   column <= e.layout.visible_right {
			cell = (e.layout.visible_top - row) * e.layout.visible_right + column - 1
		}
	}
	if e.particles[id].frame_cell == cell + 1 {
		if cell >= 0 do cell_rewin(e, cell)
		return
	}
	cell_unlink(e, id)
	if cell >= 0 do cell_link(e, id, cell)
}

// Admit a changed optional selection. Setters maintain cell ownership between
// frames; unchanged all-particle admission requires no population walk.
compose_frame :: proc(e: ^Engine, selection: Maybe([]Particle_Id) = nil) -> (width, height: int) {
	width, height = max(e.layout.visible_right, 0), max(e.layout.visible_top, 0)
	selected, restricted := selection.?
	count := len(selected) if restricted else len(e.particles)
	// The engine owns this unique ID list: effects may overwrite their slice.
	// Unchanged selections need no membership bookkeeping.
	unchanged :=
		slice.equal(selected, e.frame_candidates[:]) if restricted else len(e.frame_candidates) == len(e.particles)
	if !unchanged {
		// Two alternating marks distinguish this selection from the previous one.
		e.frame_generation = .Odd if e.frame_generation == .Even else .Even
		for i in 0 ..< count {
			when FRAME_STATS_ENABLED {e.stats.candidate_visits += 1}
			id := selected[i] if restricted else Particle_Id(i)
			added := e.particles[id].frame_selection == .Absent
			if added {
				dirty_particle_row(e, id)
				append(&e.frame_candidates, id)
			}
			e.particles[id].frame_selection = e.frame_generation
			if added do track_particle(e, id)
		}
		write := 0
		for id in e.frame_candidates {
			when FRAME_STATS_ENABLED {e.stats.candidate_visits += 1}
			if e.particles[id].frame_selection != e.frame_generation {
				dirty_particle_row(e, id)
				e.particles[id].frame_selection = .Absent
				track_particle(e, id)
			} else {
				e.frame_candidates[write] = id
				write += 1
			}
		}
		resize(&e.frame_candidates, write)
	}
	return
}

// Replace only the changed cell's bytes. Length changes shift the encoded
// suffix; offsets remain byte offsets, independent of terminal glyph width.
patch_cell :: proc(e: ^Engine, row, col: int) {
	width := e.layout.visible_right
	visual := e.frame_visuals[row * width + col]
	offsets := e.cell_offsets[row * (width + 1):(row + 1) * (width + 1)]
	start, end := offsets[col], offsets[col + 1]
	length := 1
	entry: ^Visual_Entry
	if visual != NO_VISUAL {
		entry = &e.visuals[visual - 1]
		length = int(entry.packet.length)
		if len(entry.visual.symbol) > 4 {
			length = int(entry.packet.prefix) + len(entry.visual.symbol)
			if entry.packet.prefix != 0 do length += 4
		}
	}
	out := &e.row_bytes[row]
	delta := length - (end - start)
	old_length := len(out^)
	if delta > 0 do non_zero_resize(out, old_length + delta)
	if delta != 0 {
		copy(out^[end + delta:old_length + delta], out^[end:old_length])
		if delta < 0 do resize(out, old_length + delta)
		for &offset in offsets[col + 1:] do offset += delta
	}
	when FRAME_STATS_ENABLED {
		e.stats.patched_cells += 1
		e.stats.packet_bytes_copied += length + (old_length - end if delta != 0 else 0)
	}
	bytes := out^[start:start + length]
	if visual == NO_VISUAL {
		bytes[0] = ' '
	} else if len(entry.visual.symbol) <= 4 {
		if length ==
		   48 {copy(bytes[:48], entry.packet.bytes[:48])} else {copy(bytes, entry.packet.bytes[:length])}
	} else {
		prefix := int(entry.packet.prefix)
		copy(bytes[:prefix], entry.packet.bytes[:prefix])
		copy(bytes[prefix:], entry.visual.symbol)
		if prefix != 0 do copy(bytes[length - 4:], "\x1b[0m")
	}
}

// Each dirty row is complete, so blanks erase old positions. Unchanged rows
// stay on screen. Sparse changes patch row bytes; dense changes rebuild once.
frame_build :: proc(e: ^Engine, selection: Maybe([]Particle_Id) = nil) {
	when FRAME_STATS_ENABLED {e.stats.clock = time.tick_now()}
	width, height := compose_frame(e, selection)
	when FRAME_STATS_ENABLED {stats_composed(e, width, height)}
	clear(&e.output_parts)
	for count, row in e.row_changes {
		// Shifting many variable-length cells costs more than one row rebuild.
		if count > max(width / 8, 1) do e.row_valid[row] = false
	}
	it := bit_array.make_iterator(&e.dirty_cells)
	for cell, ok := bit_array.iterate_by_set(&it); ok; cell, ok = bit_array.iterate_by_set(&it) {
		row, col := cell / width, cell % width
		if e.row_valid[row] do patch_cell(e, row, col)
	}
	bit_array.clear(&e.dirty_cells)
	cursor_row := 0
	for row in 0 ..< height {
		if !e.dirty_rows[row] do continue
		for cursor_row < row {
			append(&e.output_parts, transmute([]byte)string("\x1b[1E"))
			cursor_row += 1
		}
		out := &e.row_bytes[row]
		if !e.row_valid[row] {
			when FRAME_STATS_ENABLED {e.stats.rebuilt_rows += 1}
			non_zero_resize(out, cap(out^))
			used := 0
			blank := 0
			for visual, col in e.frame_visuals[row * width:(row + 1) * width] {
				e.cell_offsets[row * (width + 1) + col] = used + blank
				if visual == NO_VISUAL {
					blank += 1
					continue
				}
				if blank != 0 do write_output(out, &used, e.blank_row[:blank])
				blank = 0
				append_packet(e, visual, out, &used)
			}
			if blank != 0 do write_output(out, &used, e.blank_row[:blank])
			e.cell_offsets[row * (width + 1) + width] = used
			resize(out, used)
			e.row_valid[row] = true
		}
		append(&e.output_parts, out^[:])
		e.dirty_rows[row] = false
		e.row_changes[row] = 0
	}
	when FRAME_STATS_ENABLED {
		e.stats.emit += time.tick_diff(e.stats.clock, time.tick_now())
		count := 1 + len(e.output_parts)
		e.stats.parts += count
		e.stats.max_parts = max(e.stats.max_parts, count)
		e.stats.output_bytes += len(Frame_Origin)
		for part in e.output_parts do e.stats.output_bytes += len(part)
	}
}
