package engine

import "core:math/ease"

// Eased reveal of a prefix of character groups (wipe/highlight/sweep).
Group_Reveal :: struct {
	groups:   Char_Groups,
	ease:     ease.Ease,
	duration: int,
	tick:     int,
	revealed: int,
}

Group_Reveal_Change :: struct {
	added, removed: Span,
}

group_reveal_step :: proc(r: ^Group_Reveal) -> Group_Reveal_Change {
	change: Group_Reveal_Change
	if r.tick >= r.duration do return change
	r.tick += 1
	next := int(ease.ease(r.ease, f64(r.tick) / f64(r.duration)) * f64(len(r.groups.spans)))
	if next > r.revealed {
		change.added = {r.revealed, next - r.revealed}
	} else if next < r.revealed {
		change.removed = {next, r.revealed - next}
	}
	r.revealed = next
	return change
}

group_reveal_reset :: proc(r: ^Group_Reveal) {
	r.tick, r.revealed = 0, 0
}

group_reveal_complete :: proc(r: Group_Reveal) -> bool {
	return r.tick >= r.duration
}

frame :: proc(e: ^Engine, render_candidates: []Char_Id = nil) {
	enforce_framerate(e)
	frame_build(e, render_candidates)
	free_all(context.temp_allocator)
}
