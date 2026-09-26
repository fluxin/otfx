package engine

import "core:math/ease"
import "core:math/rand"
import "core:slice"

// Particle queries, ordering, flat groups, and group reveal schedules.

Particle_Filter :: bit_set[Particle_Kind;u8]

PARTICLE_FILTER_INPUT :: Particle_Filter{.Input}

PARTICLE_FILTER_ALL_FILLS :: Particle_Filter{.Input, .Inner_Fill, .Outer_Fill}

Particle_Sort :: enum {
	Top_Bottom_Left_Right,
	Random,
}

Particle_Group :: enum {
	Column_L2R,
	Column_R2L,
	Row_T2B,
	Row_B2T,
	Diagonal_TL2BR,
	Diagonal_BL2TR,
	Diagonal_TR2BL,
	Diagonal_BR2TL,
	Center_Outside,
	Outside_Center,
}

group_parse :: proc(s: string) -> (Particle_Group, bool) {
	switch s {
	case "column_left_to_right":
		return .Column_L2R, true
	case "column_right_to_left":
		return .Column_R2L, true
	case "row_top_to_bottom":
		return .Row_T2B, true
	case "row_bottom_to_top":
		return .Row_B2T, true
	case "diagonal_top_left_to_bottom_right":
		return .Diagonal_TL2BR, true
	case "diagonal_bottom_left_to_top_right":
		return .Diagonal_BL2TR, true
	case "diagonal_top_right_to_bottom_left":
		return .Diagonal_TR2BL, true
	case "diagonal_bottom_right_to_top_left":
		return .Diagonal_BR2TL, true
	case "center_to_outside":
		return .Center_Outside, true
	case "outside_to_center":
		return .Outside_Center, true
	}
	return .Column_L2R, false
}

Particle_Query :: struct {
	sets:           Particle_Sets,
	initial_coords: []Coord,
	canvas:         Canvas,
}

collect_particles :: proc(q: Particle_Query, filter: Particle_Filter) -> [dynamic]Particle_Id {
	all: [dynamic]Particle_Id
	if .Input in filter do append(&all, ..q.sets.input[:])
	if .Inner_Fill in filter do append(&all, ..q.sets.inner_fill[:])
	if .Outer_Fill in filter do append(&all, ..q.sets.outer_fill[:])
	return all
}

// Canonical order: (-row, column) — packed into a single non-negative key.
get_particles :: proc(
	q: Particle_Query,
	filter: Particle_Filter,
	srt: Particle_Sort,
) -> [dynamic]Particle_Id {
	all := collect_particles(q, filter)
	Sort_Row :: struct {
		id:  Particle_Id,
		key: int,
	}
	rows := make([]Sort_Row, len(all))
	defer delete(rows)
	// key = (max_row - row) * width + column, dense pass over the SOA fields
	width := q.canvas.right + 1
	top := q.canvas.top
	for id, i in all {
		p := q.initial_coords[id]
		rows[i] = {id, (top - p.row) * width + p.column}
	}
	slice.sort_by(rows, proc(a, b: Sort_Row) -> bool {return a.key < b.key})
	for row, i in rows do all[i] = row.id
	if srt == .Random do rand.shuffle(all[:])
	return all
}

// A span is a range into a flat pool — slices for transient views, this
// struct for spans that live inside other state.
Span :: struct {
	start, len: int,
}

span_slice :: proc(pool: []$T, sp: Span) -> []T {
	return pool[sp.start:sp.start + sp.len]
}

// Groups are one flat character pool with explicit spans into that pool.
Particle_Groups :: struct {
	members: [dynamic]Particle_Id,
	spans:   [dynamic]Span,
}

group_members :: proc(g: Particle_Groups, i: int) -> []Particle_Id {
	return span_slice(g.members[:], g.spans[i])
}

groups_delete :: proc(g: ^Particle_Groups) {
	delete(g.members[:])
	delete(g.spans[:])
}

get_particles_grouped :: proc(
	q: Particle_Query,
	filter: Particle_Filter,
	grouping: Particle_Group,
) -> Particle_Groups {
	all := collect_particles(q, filter)
	defer delete(all[:])

	Group_Row :: struct {
		id:         Particle_Id,
		group_key:  int,
		within_key: int,
	}
	rows := make([]Group_Row, len(all))
	defer delete(rows)

	reverse_groups :=
		grouping == .Column_R2L ||
		grouping == .Row_T2B ||
		grouping == .Diagonal_TR2BL ||
		grouping == .Diagonal_BR2TL ||
		grouping == .Outside_Center
	width := q.canvas.right + 1
	for id, i in all {
		p := q.initial_coords[id]
		k: int
		switch grouping {
		case .Column_L2R, .Column_R2L:
			k = p.column
		case .Row_T2B, .Row_B2T:
			k = p.row
		case .Diagonal_BL2TR, .Diagonal_TR2BL:
			k = p.row + p.column
		case .Diagonal_TL2BR, .Diagonal_BR2TL:
			k = p.column - p.row
		case .Center_Outside, .Outside_Center:
			k = abs(p.column - q.canvas.text_center.column) + abs(p.row - q.canvas.text_center.row)
		}
		if reverse_groups do k = -k
		rows[i] = {id, k, p.row * width + p.column}
	}
	slice.sort_by(rows, proc(a, b: Group_Row) -> bool {
		if a.group_key != b.group_key do return a.group_key < b.group_key
		return a.within_key < b.within_key
	})

	out: Particle_Groups
	reserve(&out.members, len(rows))
	reserve(&out.spans, len(rows))
	group_start := 0
	for row, i in rows {
		append(&out.members, row.id)
		if i > 0 && row.group_key != rows[i - 1].group_key {
			append(&out.spans, Span{group_start, i - group_start})
			group_start = i
		}
	}
	if len(rows) > 0 do append(&out.spans, Span{group_start, len(rows) - group_start})
	return out
}

// Eased reveal of a prefix of particle groups (wipe/highlight/sweep).
Group_Reveal :: struct {
	groups:   Particle_Groups,
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
	fraction := clamp(ease.ease(r.ease, f64(r.tick) / f64(r.duration)), 0, 1)
	// Some easing functions approach 1 with rounding error at the last tick.
	if r.tick == r.duration do fraction = 1
	next := int(fraction * f64(len(r.groups.spans)))
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
