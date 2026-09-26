package engine

// Particle storage, population construction, and placement publication.

Particle_Id :: distinct int

Particle :: struct {
	initial_visual_id:        Visual_Id,
	initial_coord:            Coord,
	is_visible:               bool,
	is_fill:                  bool,
	layer:                    int,
	current_coord:            Coord,
	// One logical appearance for both prepared and dynamic publication.
	visual_id:                Visual_Id,
	mutable_visual_id:        Visual_Id,
	preserve_initial_colors:  bool,
	frame_selection:          Frame_Selection,
	frame_cell:               int,
	cell_previous, cell_next: Particle_Id,
}

Particle_Storage :: #soa[dynamic]Particle

Particle_Kind :: enum {
	Input,
	Inner_Fill,
	Outer_Fill,
}

Particle_Sets :: struct {
	input:      [dynamic]Particle_Id,
	inner_fill: [dynamic]Particle_Id,
	outer_fill: [dynamic]Particle_Id,
}

make_fill_particles :: proc(e: ^Engine, occupied: []bool) {
	count := 0
	for cell in occupied {
		if !cell do count += 1
	}
	first := len(e.particles)
	resize(&e.particles, first + count)
	written := 0
	for row in 1 ..= e.canvas.top {
		for column in 1 ..= e.canvas.right {
			if occupied[(row - 1) * e.canvas.right + column - 1] do continue
			id := first + written
			e.particles.initial_coord[id] = coord(column, row)
			e.particles.current_coord[id] = e.particles.initial_coord[id]
			e.particles.is_fill[id] = true
			init_particle_visual(e, Particle_Id(id), Visual{symbol = " "})
			written += 1
			if canvas_in_text(e.canvas, coord(column, row)) {
				append(&e.particle_sets.inner_fill, Particle_Id(id))
			} else {
				append(&e.particle_sets.outer_fill, Particle_Id(id))
			}
		}
	}
}

// A build-time batch owns capacity planning. Callers specify the number of
// characters they will create, without reading or sizing engine storage.
Particle_Batch :: struct {
	engine:    ^Engine,
	remaining: int,
}

particle_batch :: proc(e: ^Engine, count: int) -> Particle_Batch {
	assert(count >= 0)
	reserve(&e.particles, len(e.particles) + count)
	reserve(&e.frame_candidates, cap(e.particles))
	reserve(&e.visuals, len(e.visuals) + count * 2)
	return {e, count}
}

add_particle :: proc {
	add_particle_single,
	add_particle_batched,
}

@(private = "file")
add_particle_batched :: #force_inline proc(
	batch: ^Particle_Batch,
	symbol: string,
	position: Coord,
) -> Particle_Id {
	assert(batch.remaining > 0)
	batch.remaining -= 1
	return add_particle_single(batch.engine, symbol, position)
}

@(private = "file")
add_particle_single :: proc(e: ^Engine, symbol: string, position: Coord) -> Particle_Id {
	c: Particle
	c.initial_coord = position
	c.current_coord = position
	append(&e.particles, c)
	reserve(&e.frame_candidates, cap(e.particles))
	id := Particle_Id(len(e.particles) - 1)
	init_particle_visual(e, id, Visual{symbol = symbol})
	return id
}

set_particle :: #force_inline proc(
	e: ^Engine,
	id: Particle_Id,
	coord: Maybe(Coord) = nil,
	visible: Maybe(bool) = nil,
	layer: Maybe(int) = nil,
	visual: union {
		Visual,
		Visual_Id,
	} = nil,
) {
	old_coord := e.particles[id].current_coord
	old_visible := e.particles[id].is_visible
	placement_changed := false
	if value, ok := coord.?; ok && value != old_coord {
		e.particles[id].current_coord = value
		placement_changed = true
	}
	if value, ok := visible.?; ok && value != old_visible {
		e.particles[id].is_visible = value
		placement_changed = true
	}
	if value, ok := layer.?; ok && value != e.particles[id].layer {
		e.particles[id].layer = value
		placement_changed = true
	}
	if placement_changed {
		if old_visible do dirty_row(e, old_coord)
		if old_visible || e.particles[id].is_visible do dirty_row(e, e.particles[id].current_coord)
		track_particle(e, id)
	}
	switch value in visual {
	case Visual:
		set_visual(e, id, value)
	case Visual_Id:
		set_visual(e, id, value)
	}
}
