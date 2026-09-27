package regression

import "../src/engine"
import "core:slice"
import "core:testing"

@(test)
value_groups_preserve_complete_keys_and_lane_order :: proc(t: ^testing.T) {
	// Equal durations alone are insufficient when start times or actions differ.
	Key :: struct {
		start, stop, action: int,
	}
	keys := [?]Key{{0, 10, 1}, {5, 15, 1}, {0, 10, 1}, {0, 10, 2}, {5, 15, 1}}
	unique, slots := engine.group_values(keys[:])
	defer delete(unique)
	defer delete(slots)
	testing.expect_value(t, len(unique), 3)
	testing.expect(t, slice.equal(slots[:], []int{0, 1, 0, 2, 1}))
	for key, i in keys do testing.expect_value(t, unique[slots[i]], key)
	for index, i in ([3]int{0, 1, 3}) do testing.expect_value(t, unique[i], keys[index])
	empty, empty_slots := engine.group_values(([]Key)(nil))
	defer delete(empty)
	defer delete(empty_slots)
	testing.expect_value(t, len(empty), 0)
	testing.expect_value(t, len(empty_slots), 0)
}

@(test)
particle_groups_preserve_coordinate_order_and_filters :: proc(t: ^testing.T) {
	// Dense and sparse keys, shuffled collection order, all group directions.
	for scale in ([2]int{1, 1_000_000}) {
		coords: [80]engine.Coord
		sets: engine.Particle_Sets
		defer delete(sets.input)
		defer delete(sets.inner_fill)
		defer delete(sets.outer_fill)
		for i in 0 ..< len(coords) {
			coords[i] = {
				column = (i % 10 + 1) * scale,
				row    = (i / 10 + 1) * scale,
			}
			id := engine.Particle_Id((i * 37) % len(coords))
			switch i % 3 {
			case 0:
				append(&sets.input, id)
			case 1:
				append(&sets.inner_fill, id)
			case 2:
				append(&sets.outer_fill, id)
			}
		}
		q := engine.Particle_Query {
			sets,
			coords[:],
			{right = 10 * scale, top = 8 * scale, text_center = {5 * scale, 4 * scale}},
		}
		for filter in ([3]engine.Particle_Filter{{}, engine.PARTICLE_FILTER_INPUT, engine.PARTICLE_FILTER_ALL_FILLS}) {
			for grouping in engine.Particle_Group {
				ids := engine.collect_particles(q, filter)
				defer delete(ids)
				Row :: struct {
					id:            engine.Particle_Id,
					group, within: int,
				}
				expected := make([]Row, len(ids))
				defer delete(expected)
				for id, i in ids {
					c := coords[id]
					key: int
					switch grouping {
					case .Column_L2R:
						key = c.column
					case .Column_R2L:
						key = -c.column
					case .Row_B2T:
						key = c.row
					case .Row_T2B:
						key = -c.row
					case .Diagonal_BL2TR:
						key = c.row + c.column
					case .Diagonal_TR2BL:
						key = -c.row - c.column
					case .Diagonal_TL2BR:
						key = c.column - c.row
					case .Diagonal_BR2TL:
						key = c.row - c.column
					case .Center_Outside:
						key =
							abs(c.column - q.canvas.text_center.column) +
							abs(c.row - q.canvas.text_center.row)
					case .Outside_Center:
						key =
							-abs(c.column - q.canvas.text_center.column) -
							abs(c.row - q.canvas.text_center.row)
					}
					expected[i] = {id, key, c.row * (q.canvas.right + 1) + c.column}
				}
				slice.sort_by(expected, proc(a, b: Row) -> bool {
					return a.group < b.group || (a.group == b.group && a.within < b.within)
				})
				actual := engine.get_particles_grouped(q, filter, grouping)
				defer engine.groups_delete(&actual)
				testing.expect_value(t, len(actual.members), len(expected))
				groups, offset := 0, 0
				for row, i in expected {
					testing.expect_value(t, actual.members[i], row.id)
					if i > 0 && row.group != expected[i - 1].group {
						testing.expect_value(
							t,
							actual.spans[groups],
							engine.Span{offset, i - offset},
						)
						groups += 1
						offset = i
					}
				}
				if len(expected) > 0 {
					testing.expect_value(
						t,
						actual.spans[groups],
						engine.Span{offset, len(expected) - offset},
					)
					groups += 1
				}
				testing.expect_value(t, len(actual.spans), groups)
			}
			ordered := engine.get_particles(q, filter, .Top_Bottom_Left_Right)
			defer delete(ordered)
			for i in 1 ..< len(ordered) {
				a, b := coords[ordered[i - 1]], coords[ordered[i]]
				testing.expect(t, a.row > b.row || (a.row == b.row && a.column < b.column))
			}
		}
	}
}
