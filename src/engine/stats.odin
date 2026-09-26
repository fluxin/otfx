package engine

import "core:time"

// Compile with -define:OTFX_FRAME_STATS=true for the phase diagnostic.
// Normal builds contain neither the counters nor their timing/observation work.
FRAME_STATS_ENABLED :: #config(OTFX_FRAME_STATS, false)

Frame_Stats :: struct {
	clock:                                                                  time.Tick,
	compose, emit, write:                                                   time.Duration,
	frames, candidate_visits, ownership_visits, dirty_rows, max_dirty_rows: int,
	parts, max_parts, output_bytes, write_calls, write_bytes:               int,
	cells, blank_cells, blank_spans, cursor_moves, long_symbols:            int,
	patched_cells, rebuilt_rows, packet_bytes_copied:                       int,
}

stats_composed :: proc(e: ^Engine, width, height: int) {
	when FRAME_STATS_ENABLED {
		e.stats.compose += time.tick_diff(e.stats.clock, time.tick_now())
		e.stats.frames += 1
		dirty, cursor := 0, 0
		for row in 0 ..< height {
			if !e.dirty_rows[row] do continue
			dirty += 1
			e.stats.cursor_moves += row - cursor
			cursor = row
			blank := false
			for id in e.frame_particles[row * width:(row + 1) * width] {
				e.stats.cells += 1
				if id < 0 {
					e.stats.blank_cells += 1
					if !blank do e.stats.blank_spans += 1
					blank = true
				} else {
					blank = false
					if len(e.visuals[e.particles[id].visual_id - 1].visual.symbol) > 4 do e.stats.long_symbols += 1
				}
			}
		}
		e.stats.dirty_rows += dirty
		e.stats.max_dirty_rows = max(e.stats.max_dirty_rows, dirty)
		e.stats.clock = time.tick_now()
	}
}

when FRAME_STATS_ENABLED {
	Frame_Stats_State :: Frame_Stats
} else {
	Frame_Stats_State :: struct {}
}
