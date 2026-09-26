package engine

Row_Flag :: enum {
	Placement,
	Appearance,
	Long_Symbol,
}
Row :: struct {
	bytes: []byte,
	flags: bit_set[Row_Flag],
}

cell_bytes :: #force_inline proc(e: ^Engine) -> int {
	return Glyph_Bytes if e.cfg.no_color else Cell_Bytes
}

frame :: proc(e: ^Engine, selected: Maybe([]Particle_Id) = nil) {
	enforce_framerate(e)
	frame_build(e, selected)
	free_all(context.temp_allocator)
}

// Coordinates are bottom-up; renderer rows are top-down.
dirty_row :: #force_inline proc(e: ^Engine, coord: Coord) {
	row := coord.row + e.layout.row_offset
	if row < e.layout.visible_bottom || row > e.layout.visible_top do return
	e.rows[e.layout.visible_top - row].flags += {.Placement}
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
	for row, i in e.rows {
		if .Placement in row.flags do for &id in e.frame_particles[i * width:(i + 1) * width] do id = -1
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
		if .Placement not_in e.rows[height - row].flags do continue
		cell := &e.frame_particles[(height - row) * width + column - 1]
		if cell^ >= 0 {
			priority, prior := e.particles.layer[id], e.particles.layer[cell^]
			if priority < prior || (priority == prior && id <= cell^) do continue
		}
		cell^ = id
	}
	return
}

// Row bytes persist between frames. Appearance edits already patched their
// slots; only placement changes require encoding the resolved row again.
frame_build :: proc(e: ^Engine, selection: Maybe([]Particle_Id) = nil) {
	width, _ := compose_frame(e, selection)
	clear(&e.output_parts)
	stride := cell_bytes(e)
	cursor_row := 0
	for &row, i in e.rows {
		if row.flags & {.Placement, .Appearance} == {} do continue
		ids := e.frame_particles[i * width:(i + 1) * width]
		if .Placement in row.flags {
			row.flags -= {.Long_Symbol}
			for id, column in ids {
				bytes := row.bytes[column * stride:(column + 1) * stride]
				if id < 0 {
					blank := Visual {
						symbol = " ",
					}
					packet_update(bytes, &blank, &e.cfg, All_Packet_Fields)
				} else {
					write_cell(e, id, bytes, All_Packet_Fields)
					if len(get_visual(e, id).symbol) > Glyph_Bytes do row.flags += {.Long_Symbol}
				}
			}
		}
		for cursor_row < i {
			append(&e.output_parts, transmute([]byte)string("\x1b[1E"))
			cursor_row += 1
		}
		start := 0
		// Rare long symbols borrow their full string between row slices.
		if .Long_Symbol in row.flags {
			prefix := 0 if e.cfg.no_color else 43
			for id, column in ids {
				if id < 0 do continue
				symbol := get_visual(e, id).symbol
				if len(symbol) <= Glyph_Bytes do continue
				end := column * stride + prefix
				append(&e.output_parts, row.bytes[start:end], transmute([]byte)symbol)
				start = end + Glyph_Bytes
			}
		}
		append(&e.output_parts, row.bytes[start:])
		row.flags -= {.Placement, .Appearance}
	}
}
