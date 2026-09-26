package engine

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
	if value, ok := coord.?; ok && value != e.particles.current_coord[id] {
		dirty_particle_row(e, id)
		e.particles.current_coord[id] = value
		dirty_particle_row(e, id)
	}
	if value, ok := visible.?; ok && value != e.particles.is_visible[id] {
		dirty_row(e, e.particles.current_coord[id])
		e.particles.is_visible[id] = value
	}
	if value, ok := layer.?; ok && value != e.particles.layer[id] {
		e.particles.layer[id] = value
		dirty_particle_row(e, id)
	}
	switch value in visual {
	case Visual:
		set_visual(e, id, value)
	case Visual_Id:
		set_visual(e, id, value)
	}
}
