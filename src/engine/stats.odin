package engine

import "core:container/bit_array"
import "core:time"

// Compile with -define:OTFX_FRAME_STATS=true for the phase diagnostic.
// Normal builds contain neither the counters nor their timing/observation work.
FRAME_STATS_ENABLED :: #config(OTFX_FRAME_STATS, false)

Frame_Stats :: struct {
	clock:                                                                  time.Tick,
	compose, emit, write:                                                   time.Duration,
	frames, candidate_visits, ownership_visits, dirty_rows, max_dirty_rows: int,
	parts, max_parts, output_bytes, write_calls, write_bytes:               int,
	cells, blank_cells, blank_spans, cursor_moves:                          int,
	patched_cells, cell_bytes_written:                                      int,
}

stats_composed :: proc(e: ^Engine) {
	when FRAME_STATS_ENABLED {
		e.stats.compose += time.tick_diff(e.stats.clock, time.tick_now())
		e.stats.frames += 1
		e.stats.clock = time.tick_now()
	}
}

stats_rows :: proc(e: ^Engine) {
	when FRAME_STATS_ENABLED {
		dirty, cursor := 0, 0
		rows := bit_array.make_iterator(&e.emit_rows)
		for row_index, ok := next_dirty_bit(&rows); ok; row_index, ok = next_dirty_bit(&rows) {
			row := &e.rows[row_index]
			dirty += 1
			e.stats.cursor_moves += int(row_index != cursor)
			cursor = row_index
			blank := false
			for cell in row.cells {
				e.stats.cells += 1
				if cell.top == NO_PARTICLE {
					e.stats.blank_cells += 1
					if !blank do e.stats.blank_spans += 1
					blank = true
				} else {
					blank = false
				}
			}
		}
		e.stats.dirty_rows += dirty
		e.stats.max_dirty_rows = max(e.stats.max_dirty_rows, dirty)
	}
}

when FRAME_STATS_ENABLED {
	Frame_Stats_State :: Frame_Stats
} else {
	Frame_Stats_State :: struct {}
}
