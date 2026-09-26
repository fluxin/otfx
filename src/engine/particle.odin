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
