package engine

import "core:slice"

frame :: proc(e: ^Engine, selected: Maybe([]Particle_Id) = nil) {
	enforce_framerate(e)
	frame_build(e, selected)
	free_all(context.temp_allocator)
}

// One transient draw per visible particle; sorting makes overlap resolution
// deterministic without a retained cell grid or membership lists.
Draw :: struct {
	cell:     int,
	particle: Particle_Id,
}

build_draws :: proc(e: ^Engine, selection: Maybe([]Particle_Id) = nil) -> (width, height: int) {
	width, height = max(e.layout.visible_right, 0), max(e.layout.visible_top, 0)
	clear(&e.draws)
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
		append(&e.draws, Draw{(height - row) * width + column - 1, id})
	}
	slice.sort_by(e.draws[:], proc(a, b: Draw) -> bool {return a.cell < b.cell})
	write := 0
	for draw in e.draws {
		if write != 0 && e.draws[write - 1].cell == draw.cell {
			previous := e.draws[write - 1].particle
			priority, prior := e.particles.layer[draw.particle], e.particles.layer[previous]
			if priority > prior || (priority == prior && draw.particle > previous) do e.draws[write - 1] = draw
		} else {
			e.draws[write] = draw
			write += 1
		}
	}
	resize(&e.draws, write)
	return
}

// Every row is complete: blank spans erase old positions, and packets already
// contain their appearance bytes. No previous frame or dirty state is needed.
frame_build :: proc(e: ^Engine, selection: Maybe([]Particle_Id) = nil) {
	width, height := build_draws(e, selection)
	clear(&e.output_parts)
	next := 0
	for row in 0 ..< height {
		if row != 0 do append(&e.output_parts, transmute([]byte)string("\x1b[1E"))
		column := 0
		for next < len(e.draws) && e.draws[next].cell < (row + 1) * width {
			draw := e.draws[next]
			target := draw.cell - row * width
			if target > column do append(&e.output_parts, e.blank_row[:target - column])
			append_packet(e, draw.particle)
			column = target + 1
			next += 1
		}
		if column < width do append(&e.output_parts, e.blank_row[:width - column])
	}
}
