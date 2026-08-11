package engine

import ease "core:math/ease"

// ---------------------------------------------------------------------------
// pools
// ---------------------------------------------------------------------------

new_scene :: proc(e: ^Engine, looping: bool, ease: Maybe(ease.Ease)) -> int {
	s: Scene
	s.looping = looping
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

	if s.ease != nil {
		step_eased_scene(e, id, scene_handle, s.ease.?)
	} else {
		character_set_visual(&e.chars, id, scene_next_visual(s))
	}
	complete_scene_if_finished(e, id, scene_handle)
}

step_eased_scene :: proc(e: ^Engine, id: Char_Id, scene_handle: int, fn: ease.Ease) {
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

// Advance and compact the active scenes in ascending activation order.
update :: proc(e: ^Engine) {
	active_scenes := e.chars.active_scene
	scenes := e.scenes[:]
	in_active := e.in_active[:]
	write := 0
	for id in e.active {
		step_animation(e, id)
		if char_is_active(active_scenes[id], scenes) {
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
