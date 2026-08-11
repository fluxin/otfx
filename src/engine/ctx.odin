package engine

// All stepping logic. Events are flat data rows; actions run inline and
// reentrantly (an action may activate another path/scene mid-step), which the
// handle-based pools absorb without any re-borrow gymnastics.

// ---------------------------------------------------------------------------
// pools
// ---------------------------------------------------------------------------

new_path :: proc(
	e: ^Engine,
	speed: f64,
	ease: Maybe(Easing),
	layer: Maybe(int),
	hold_time: int,
	looping: bool,
) -> int {
	append(&e.paths, path_make(speed, ease, layer, hold_time, looping))
	return len(e.paths) - 1
}

path_clear :: proc(p: ^Path) {
	clear(&p.waypoints)
	clear(&p.cum)
	p.origin_dist = 0
	p.total = 0
	p.step, p.max_steps, p.last_dist = 0, 0, 0
}

new_scene :: proc(e: ^Engine, looping: bool, sync: Sync, ease: Maybe(Easing)) -> int {
	s: Scene
	s.looping = looping
	s.sync = sync
	s.ease = ease
	append(&e.scenes, s)
	return len(e.scenes) - 1
}

// Eased reveal of a sequence of groups (wipe/highlight/sweep). Groups are
// flat storage + offsets; step() reports the added/removed group range.
Sequence_Easer :: struct {
	groups:  Char_Groups,
	tracker: Easing_Tracker,
}

seq_group_range :: struct {
	added_start, added_end:     int,
	removed_start, removed_end: int,
}

seq_step :: proc(se: ^Sequence_Easer) -> seq_group_range {
	r: seq_group_range
	previous_eased := se.tracker.eased_value
	eased := tracker_step(&se.tracker)
	n := group_count(se.groups)
	if n == 0 do return r
	length := int(eased * f64(n))
	previous := int(previous_eased * f64(n))
	if length > previous {
		r.added_start, r.added_end = previous, length
	} else if length < previous {
		r.removed_start, r.removed_end = length, previous
	}
	return r
}

seq_complete :: proc(se: Sequence_Easer) -> bool {
	return tracker_complete(se.tracker)
}

// ---------------------------------------------------------------------------
// motion
// ---------------------------------------------------------------------------

activate_path :: proc(e: ^Engine, id: Char_Id, handle: int) {
	p := &e.paths[handle]
	assert(len(p.waypoints) > 0, "activate_path: empty path")
	origin := e.chars.current_coord[id]
	p.origin = origin
	first := p.waypoints[0]
	p.origin_dist =
		first.control != nil ? quadratic_bezier_length(origin, first.control.?, first.coord) : line_length(origin, first.coord, true)
	p.total = p.origin_dist + p.cum[len(p.cum) - 1]
	p.step = 0
	p.hold_remaining = p.hold_time
	p.max_steps = round_half_even(p.total / p.speed)
	p.last_dist = 0
	e.chars.active_path[id] = handle
	if p.layer != nil do e.chars.layer[id] = p.layer.?
}

// One step along the path; segment walk with eased-overshoot semantics.
path_step :: proc(p: ^Path) -> Coord {
	if p.max_steps == 0 || p.step >= p.max_steps || p.total == 0.0 {
		return p.waypoints[len(p.waypoints) - 1].coord
	}
	p.step += 1
	ratio := f64(p.step) / f64(p.max_steps)
	factor := p.ease != nil ? easing_apply(p.ease.?, ratio) : ratio
	d := factor * p.total
	p.last_dist = d

	// segments: [0] origin->wp0 (origin_dist), [i] wp[i-1]->wp[i]
	nseg := len(p.waypoints)
	seg_len :: proc(origin_dist: f64, cum: []f64, i: int) -> f64 {
		return i == 0 ? origin_dist : cum[i] - cum[i - 1]
	}
	active := -1
	for i in 0 ..< nseg {
		l := seg_len(p.origin_dist, p.cum[:], i)
		if d <= l {
			active = i
			break
		}
		d -= l
	}
	if active < 0 {
		// eased overshoot past the final waypoint: add the last segment back
		active = nseg - 1
		d += seg_len(p.origin_dist, p.cum[:], active)
	}
	l := seg_len(p.origin_dist, p.cum[:], active)
	t := l == 0.0 ? 0.0 : d / l
	if p.ease == nil do t = min(t, 1.0)
	start := active == 0 ? p.origin : p.waypoints[active - 1].coord
	waypoint := p.waypoints[active]
	if waypoint.control != nil do return coord_on_quadratic_bezier(start, waypoint.control.?, waypoint.coord, t)
	return coord_on_line(start, waypoint.coord, t)
}

motion_move :: proc(e: ^Engine, id: Char_Id) {
	e.chars.previous_coord[id] = e.chars.current_coord[id]
	handle := e.chars.active_path[id]
	if handle < 0 do return
	p := &e.paths[handle]
	if len(p.waypoints) == 0 do return

	e.chars.current_coord[id] = path_step(p)

	// An action during stepping may have swapped the active path; re-read.
	handle = e.chars.active_path[id]
	if handle < 0 do return
	p = &e.paths[handle]

	if p.step == p.max_steps {
		if p.hold_time != 0 && p.hold_remaining == p.hold_time {
			p.hold_remaining -= 1
			return
		}
		if p.hold_remaining != 0 {
			p.hold_remaining -= 1
			return
		}
		if p.looping && len(p.waypoints) > 1 {
			e.chars.active_path[id] = -1
			activate_path(e, id, handle)
		} else {
			e.chars.completed_path[id] = handle
			e.chars.active_path[id] = -1
		}
	}
}

// ---------------------------------------------------------------------------
// animation
// ---------------------------------------------------------------------------

activate_scene :: proc(e: ^Engine, id: Char_Id, handle: int) {
	s := &e.scenes[handle]
	assert(len(s.frames) > 0, "activate_scene: empty scene")
	e.chars.active_scene[id] = handle
	character_set_visual(&e.chars, id, scene_first_visual(s^))
}

step_animation :: proc(e: ^Engine, id: Char_Id) {
	scene_handle := e.chars.active_scene[id]
	if scene_handle < 0 do return
	s := &e.scenes[scene_handle]
	if len(s.frames) == 0 do return

	switch {
	case s.sync != .None:
		step_synced_scene(e, id, scene_handle, s.sync)
	case s.ease != nil:
		step_eased_scene(e, id, scene_handle, s.ease.?)
	case:
		character_set_visual(&e.chars, id, scene_next_visual(s))
	}
	complete_scene_if_finished(e, id, scene_handle)
}

// Sync a scene against the character's active path progress.
step_synced_scene :: proc(e: ^Engine, id: Char_Id, scene_handle: int, sync: Sync) {
	handle := e.chars.active_path[id]
	s := &e.scenes[scene_handle]
	n := len(s.frames)
	if handle < 0 {
		// no active path: jump to the final frame and force completion
		character_set_visual(&e.chars, id, s.frames[n - 1].visual)
		s.played = n
		return
	}
	p := &e.paths[handle]
	progress := 0.0
	switch sync {
	case .Step:
		progress = f64(max(p.step, 1)) / f64(max(p.max_steps, 1))
	case .Distance:
		total := max(p.total, 1.0)
		remaining := max(p.total - p.last_dist, 1.0)
		reached := max(total - remaining, 1.0)
		progress = reached / total
	case .None:
		unreachable()
	}
	final := n - 1
	frame := clamp(round_half_even(f64(final) * progress), 0, final)
	character_set_visual(&e.chars, id, s.frames[s.played + frame].visual)
}

step_eased_scene :: proc(e: ^Engine, id: Char_Id, scene_handle: int, fn: Easing) {
	s := &e.scenes[scene_handle]
	frame := eased_timeline_index(s.easing_current_step, max(s.easing_total_steps, 1), fn)
	character_set_visual(&e.chars, id, s.frames[s.frame_index_map[frame]].visual)

	s.easing_current_step += 1
	if s.easing_current_step == s.easing_total_steps {
		if s.looping {
			s.easing_current_step = 0
		} else {
			s.played = len(s.frames)
		}
	}
}

complete_scene_if_finished :: proc(e: ^Engine, id: Char_Id, scene_handle: int) {
	s := &e.scenes[scene_handle]
	if !scene_complete(s^) do return
	if !s.looping {
		scene_reset(s)
		e.chars.active_scene[id] = -1
	}
}

// ---------------------------------------------------------------------------
// tick / update / frame
// ---------------------------------------------------------------------------

tick :: proc(e: ^Engine, id: Char_Id) {
	motion_move(e, id)
	step_animation(e, id)
}

// Tick a snapshot of the active set (ascending insert order), then prune.
update :: proc(e: ^Engine) {
	scratch := &e.active_scratch
	clear(scratch)
	append(scratch, ..e.active[:])
	for id in scratch^ {
		tick(e, id)
	}
	active_paths := e.chars.active_path
	active_scenes := e.chars.active_scene
	scenes := e.scenes[:]
	in_active := e.in_active[:]
	write := 0
	for id in e.active {
		if char_is_active(active_paths[id], active_scenes[id], scenes) {
			e.active[write] = id
			write += 1
		} else {
			in_active[id] = 0
		}
	}
	resize(&e.active, write)
}

frame :: proc(e: ^Engine, render_candidates: []Char_Id = nil) {
	enforce_framerate(e)
	frame_build(e, render_candidates)
	free_all(context.temp_allocator)
}

// ---------------------------------------------------------------------------
// character ops used by effects
// ---------------------------------------------------------------------------

active_insert :: proc(e: ^Engine, id: Char_Id) {
	if e.in_active[id] != 0 do return
	e.in_active[id] = 1
	append(&e.active, id)
}

active_clear :: proc(e: ^Engine) {
	for id in e.active do e.in_active[id] = 0
	clear(&e.active)
}

// Immediate appearance override (matrix/beams per-frame swaps).
set_appearance :: proc(
	chars: ^Character_Storage,
	id: Char_Id,
	symbol: string,
	fg, bg: Maybe(Color),
) {
	character_set_visual(chars, id, visual_make(symbol, fg, bg, false))
}
