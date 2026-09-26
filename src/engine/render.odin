package engine

import "core:simd"

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
	// Candidate inclusion can change without any particle setter being called.
	for &state in e.particles.frame_selection[:len(e.particles)] do if state == .Present do state = .Pending
	for i in 0 ..< count {
		id := selected[i] if restricted else Particle_Id(i)
		if e.particles.frame_selection[id] == .Absent do dirty_particle_row(e, id)
		e.particles.frame_selection[id] = .Present
	}
	for state, id in e.particles.frame_selection[:len(e.particles)] {
		if state != .Pending do continue
		dirty_particle_row(e, Particle_Id(id))
		e.particles.frame_selection[id] = .Absent
	}
	for dirty, row in e.dirty_rows {
		if dirty do for &id in e.frame_particles[row * width:(row + 1) * width] do id = -1
	}
	if e.layout.visible_right < e.layout.visible_left ||
	   e.layout.visible_top < e.layout.visible_bottom {
		return
	}
	for i in 0 ..< count {
		id := selected[i] if restricted else Particle_Id(i)
		if !e.particles.is_visible[id] do continue
		p := e.particles.current_coord[id]
		row, column := p.row + e.layout.row_offset, p.column + e.layout.col_offset
		// Test both axes together. Unsigned distances also reject negative positions.
		distance := #simd[2]uint {
			uint(column - e.layout.visible_left),
			uint(row - e.layout.visible_bottom),
		}
		extent := #simd[2]uint {
			uint(e.layout.visible_right - e.layout.visible_left),
			uint(e.layout.visible_top - e.layout.visible_bottom),
		}
		if simd.extract_msbs(simd.lanes_gt(distance, extent)) != {} {
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
