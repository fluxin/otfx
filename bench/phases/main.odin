package main

import "../../src/effects"
import "../../src/engine"
import "core:fmt"
import "core:math/rand"
import "core:mem"
import "core:os"
import "core:time"

trial :: proc(input: string, kind: effects.Effect_Kind, sample: int) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	rand.reset_u64(1)
	cfg := engine.config_default()
	cfg.frame_rate = 0
	e, err := engine.engine_make(input, cfg, context.allocator)
	assert(err == .None)
	fx, ok := effects.make_effect(kind, nil)
	assert(ok)
	effects.build_effect(&fx, &e)
	free_all(context.temp_allocator)
	update, render: time.Duration
	frames, candidates, parts: int
	for {
		start := time.tick_now()
		ids, alive := effects.next_frame(&fx, &e)
		stepped := time.tick_now()
		if !alive do break
		if ids == nil {engine.frame_build(&e)} else {engine.frame_build(&e, ids)}
		built := time.tick_now()
		update += time.tick_diff(start, stepped)
		render += time.tick_diff(stepped, built)
		frames += 1
		candidates += len(e.particles) if ids == nil else len(ids)
		parts += len(e.output_parts)
		free_all(context.temp_allocator)
	}
	fmt.printf(
		"%v\t%d\t%d\t%.6f\t%.6f\t%d\t%d\t%d\t%d\n",
		kind,
		sample,
		frames,
		time.duration_milliseconds(update),
		time.duration_milliseconds(render),
		candidates,
		parts,
		e.layout.visible_right,
		e.layout.visible_top,
	)
}

main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintln(
			"usage: phases INPUT_FILE (set COLUMNS=200 LINES=50 for the reference workload)",
		)
		os.exit(1)
	}
	input, err := os.read_entire_file(os.args[1], context.allocator)
	assert(err == nil)
	defer delete(input)
	fmt.println(
		"effect\tsample\tframes\tupdate_ms\tframe_build_ms\tcandidates\toutput_parts\twidth\theight",
	)
	for kind in ([]effects.Effect_Kind{.Colorshift, .Decrypt, .Binarypath, .Burn, .Laseretch, .Rain}) {
		for sample in 0 ..< 5 do trial(string(input), kind, sample)
	}
}
