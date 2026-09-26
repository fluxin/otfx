package engine

import "core:slice"

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

// Rebuild dirty rows. Empty cells are -1; overlaps select the highest layer,
// then the latest particle. Candidate order does not affect the result.
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
			id := selected[i] if restricted else Particle_Id(i)
			if e.particles[id].frame_selection == .Absent {
				dirty_particle_row(e, id)
				append(&e.frame_candidates, id)
			}
			e.particles[id].frame_selection = e.frame_generation
		}
		write := 0
		for id in e.frame_candidates {
			if e.particles[id].frame_selection != e.frame_generation {
				dirty_particle_row(e, id)
				e.particles[id].frame_selection = .Absent
			} else {
				e.frame_candidates[write] = id
				write += 1
			}
		}
		resize(&e.frame_candidates, write)
	}
	for dirty, row in e.dirty_rows {
		if dirty do for &id in e.frame_particles[row * width:(row + 1) * width] do id = -1
	}
	for i in 0 ..< count {
		id := selected[i] if restricted else Particle_Id(i)
		if !e.particles.is_visible[id] do continue
		p := e.particles.current_coord[id]
		row, column := p.row + e.layout.row_offset, p.column + e.layout.col_offset
		if row < e.layout.visible_bottom ||
		   row > e.layout.visible_top ||
		   column < e.layout.visible_left ||
		   column > e.layout.visible_right {
			continue
		}
		if !e.dirty_rows[height - row] do continue
		cell := &e.frame_particles[(height - row) * width + column - 1]
		if cell^ >= 0 {
			priority, prior := e.particles.layer[id], e.particles.layer[cell^]
			if priority < prior || (priority == prior && id <= cell^) do continue
		}
		cell^ = id
	}
	return
}

// Each dirty row is complete, so blanks erase old positions. Unchanged rows
// stay on screen; packet slices already contain their appearance bytes.
frame_build :: proc(e: ^Engine, selection: Maybe([]Particle_Id) = nil) {
	width, height := compose_frame(e, selection)
	clear(&e.output_parts)
	cursor_row := 0
	for row in 0 ..< height {
		if !e.dirty_rows[row] do continue
		for cursor_row < row {
			append(&e.output_parts, transmute([]byte)string("\x1b[1E"))
			cursor_row += 1
		}
		blank := 0
		for id in e.frame_particles[row * width:(row + 1) * width] {
			if id < 0 {
				blank += 1
				continue
			}
			if blank != 0 do append(&e.output_parts, e.blank_row[:blank])
			blank = 0
			append_packet(e, id)
		}
		if blank != 0 do append(&e.output_parts, e.blank_row[:blank])
		e.dirty_rows[row] = false
	}
}
