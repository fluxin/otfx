package engine

frame :: proc(e: ^Engine, selected: Maybe([]Particle_Id) = nil) {
	enforce_framerate(e)
	frame_build(e, selected)
	free_all(context.temp_allocator)
}

// Rebuild one top-down frame. Empty cells are -1; overlaps select the highest
// layer, then the latest particle. Candidate order does not affect the result.
compose_frame :: proc(e: ^Engine, selection: Maybe([]Particle_Id) = nil) -> (width, height: int) {
	width, height = max(e.layout.visible_right, 0), max(e.layout.visible_top, 0)
	for &id in e.frame_particles do id = -1
	selected, restricted := selection.?
	count := len(selected) if restricted else len(e.particles)
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
		cell := &e.frame_particles[(height - row) * width + column - 1]
		if cell^ >= 0 {
			priority, prior := e.particles.layer[id], e.particles.layer[cell^]
			if priority < prior || (priority == prior && id <= cell^) do continue
		}
		cell^ = id
	}
	return
}

// Every row is complete: blank spans erase old positions, and packets already
// contain their appearance bytes. No previous frame or dirty state is needed.
frame_build :: proc(e: ^Engine, selection: Maybe([]Particle_Id) = nil) {
	width, height := compose_frame(e, selection)
	clear(&e.output_parts)
	for row in 0 ..< height {
		if row != 0 do append(&e.output_parts, transmute([]byte)string("\x1b[1E"))
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
	}
}
