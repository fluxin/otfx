package main

import "../../src/effects"
import "../../src/engine"
import "core:fmt"
import "core:math/rand"
import "core:mem"
import "core:os"
import "core:time"

trial :: proc(input: string, kind: effects.Effect_Kind, sample: int, print: bool) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	rand.reset_u64(1)
	cfg := engine.config_default()
	cfg.frame_rate = 0
	e, err := engine.engine_make(input, cfg)
	assert(err == .None)
	fx, ok := effects.make_effect(kind, nil)
	assert(ok)
	effects.build_effect(&fx, &e)
	free_all(context.temp_allocator)
	when engine.FRAME_STATS_ENABLED {e.stats = {}}
	update, frame_build: time.Duration
	frames := 0
	playback_start := time.tick_now()
	for {
		start := time.tick_now()
		alive := effects.next_frame(&fx, &e)
		stepped := time.tick_now()
		if !alive do break
		engine.frame_build(&e)
		built := time.tick_now()
		update += time.tick_diff(start, stepped)
		frame_build += time.tick_diff(stepped, built)
		if print do engine.print_frame(&e)
		free_all(context.temp_allocator)
		frames += 1
	}
	playback := time.tick_diff(playback_start, time.tick_now())
	when engine.FRAME_STATS_ENABLED {
		s := e.stats
		other := playback - update - s.compose - s.emit - s.write
		fmt.eprintf(
			"%v\t%d\t%d\t%.6f\t%.6f\t%.6f\t%.6f\t%.6f\t%.6f\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",
			kind,
			sample,
			frames,
			time.duration_milliseconds(update),
			time.duration_milliseconds(s.compose),
			time.duration_milliseconds(s.emit),
			time.duration_milliseconds(s.write),
			time.duration_milliseconds(playback),
			time.duration_milliseconds(other),
			s.dirty_rows,
			s.max_dirty_rows,
			s.parts,
			s.max_parts,
			s.write_calls,
			s.write_bytes,
			s.candidate_visits,
			s.cells,
			s.blank_cells,
			s.blank_spans,
			s.cursor_moves,
			s.patched_cells,
			s.cell_bytes_written,
			s.ownership_visits,
		)
	} else {
		fmt.eprintf(
			"%v\t%d\t%d\t%.6f\t%.6f\t%.6f\n",
			kind,
			sample,
			frames,
			time.duration_milliseconds(update),
			time.duration_milliseconds(frame_build),
			time.duration_milliseconds(playback),
		)
	}
}
main :: proc() {
	if len(os.args) < 2 || len(os.args) > 3 || (len(os.args) == 3 && os.args[2] != "--print") {
		fmt.eprintln(
			"usage: phases INPUT_FILE [--print]; set COLUMNS/LINES to match the CLI benchmark",
		)
		os.exit(1)
	}
	input, err := os.read_entire_file(os.args[1], context.allocator)
	assert(err == nil)
	defer delete(input)
	when engine.FRAME_STATS_ENABLED {
		fmt.eprintln(
			"effect\tsample\tframes\tupdate_ms\tcompose_ms\temit_ms\twrite_ms\tplayback_ms\tother_ms\tdirty_rows\tmax_dirty_rows\tdescriptors\tmax_descriptors\twritev_calls\twrite_bytes\tcandidate_visits\tcells\tblank_cells\tblank_spans\tcursor_moves\tpatched_cells\tcell_bytes_written\townership_visits",
		)
	} else {fmt.eprintln("effect\tsample\tframes\tupdate_ms\tframe_build_ms\tplayback_ms")}
	for kind in ([]effects.Effect_Kind{.Colorshift, .Decrypt, .Binarypath, .Burn, .Laseretch, .Rain, .Print}) {
		for sample in 0 ..< 3 do trial(string(input), kind, sample, len(os.args) == 3)
	}
}
