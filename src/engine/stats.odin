package engine

import "core:time"

// Compile with -define:OTFX_FRAME_STATS=true for the phase diagnostic.
// Normal builds contain neither the counters nor their timing/observation work.
FRAME_STATS_ENABLED :: #config(OTFX_FRAME_STATS, false)

Frame_Stats :: struct {
	clock:                                        time.Tick,
	compose, emit, write:                         time.Duration,
	frames, candidate_visits, ownership_visits:   int,
	runs, output_bytes, write_calls, write_bytes: int,
	patched_cells, cell_bytes_written:            int,
}

stats_composed :: proc(e: ^Engine) {
	when FRAME_STATS_ENABLED {
		e.stats.compose += time.tick_diff(e.stats.clock, time.tick_now())
		e.stats.frames += 1
		e.stats.clock = time.tick_now()
	}
}

when FRAME_STATS_ENABLED {
	Frame_Stats_State :: Frame_Stats
} else {
	Frame_Stats_State :: struct {}
}
