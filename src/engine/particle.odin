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
	if value, ok := coord.?; ok {
		e.particles.current_coord[id] = value
	}
	if value, ok := visible.?; ok {
		e.particles.is_visible[id] = value
	}
	if value, ok := layer.?; ok {
		e.particles.layer[id] = value
	}
	switch value in visual {
	case Visual:
		set_visual(e, id, value)
	case Visual_Id:
		set_visual(e, id, value)
	}
}
