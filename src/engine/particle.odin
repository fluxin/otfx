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
	if value, ok := coord.?; ok && value != e.particles[id].current_coord {
		dirty_particle_row(e, id)
		e.particles[id].current_coord = value
		dirty_particle_row(e, id)
	}
	if value, ok := visible.?; ok && value != e.particles[id].is_visible {
		dirty_row(e, e.particles[id].current_coord)
		e.particles[id].is_visible = value
	}
	if value, ok := layer.?; ok && value != e.particles[id].layer {
		e.particles[id].layer = value
		dirty_particle_row(e, id)
	}
	switch value in visual {
	case Visual:
		set_visual(e, id, value)
	case Visual_Id:
		set_visual(e, id, value)
	}
}
