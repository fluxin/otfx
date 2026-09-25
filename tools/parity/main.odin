package main

import common "../common"

import "../../src/effects"
import "../../src/engine"

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

// Logical-frame diagnostics between otfx and the ttfx reference.
// Reasonable reference differences are accepted; completion and final content
// are checked independently of exact frame counts.
//
// Built as a standalone tool rather than as a flag on the shipping binary: the
// product has no reason to carry a dump mode. The otfx side links the engine
// directly and steps it here; the ttfx side is spawned and its emitted frames
// counted, so nothing outside this directory knows parity work exists.
//
// A frame count only means something under a virtual clock. matrix and
// thunderstorm end their middle phase on elapsed seconds, so unpaced they race
// the host and the count measures throughput rather than behaviour.
//
// Usage: parity [effect-name-filter]

Canvas_Width :: 80
Canvas_Height :: 24
Seed :: 1
Max_Frames :: 200_000 // backstop; a converging effect never reaches this

Input :: "Hello, World!\nThis is otfx.\nOdin vs Rust"
Reference :: "third_party/ttfx/target/release/ttfx"

// The terminal sequence each implementation writes once per emitted frame.
Frame_Marker :: [4]byte{'\x1b', '8', '\x1b', '7'}

// Only effects needing non-default arguments are listed; everything else runs
// at its defaults. The two seconds-budgeted effects are shortened so a case
// does not spend its whole budget in one phase.
case_args :: proc(kind: effects.Effect_Kind) -> []string {
	@(static) rain := []string{"--rain-time", "1"}
	@(static) storm := []string{"--storm-time", "1"}
	#partial switch kind {
	case .Matrix:
		return rain
	case .Thunderstorm:
		return storm
	}
	return nil
}

otfx_frames :: proc(kind: effects.Effect_Kind) -> (int, bool) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.frame_rate = 0
	cfg.canvas_width = Canvas_Width
	cfg.canvas_height = Canvas_Height
	cfg.ignore_terminal_dimensions = true
	cfg.virtual_clock = true

	run, ok := common.run_make(kind, case_args(kind), cfg, Input, Seed)
	if !ok do return 0, false
	frames := 0
	for frames < Max_Frames {
		_, _, produced := common.run_step(&run)
		if !produced do break
		frames += 1
		free_all(context.temp_allocator)
	}
	if frames == Max_Frames do return frames, false
	// Inspect the last rendered grid, including painter collisions.
	e := &run.engine_state
	for id in e.character_sets.input {
		p := e.chars.input_coord[id]
		cell := e.render_cells[(p.row - 1) * e.visible_right + p.column - 1]
		if cell < 0 || e.chars.visual[cell].symbol != e.chars.input_symbol[id] do return frames, false
	}
	return frames, true
}

// Streams the reference's output and counts frame markers as they arrive, so a
// long effect never has to be buffered in full.
reference_frames :: proc(kind: effects.Effect_Kind) -> (int, bool) {
	command: [dynamic]string
	defer delete(command)
	append(
		&command,
		Reference,
		"--seed",
		fmt.tprintf("%d", Seed),
		"--frame-rate",
		"0",
		"--virtual-clock",
		"--canvas-width",
		fmt.tprintf("%d", Canvas_Width),
		"--canvas-height",
		fmt.tprintf("%d", Canvas_Height),
		"--ignore-terminal-dimensions",
		common.effect_name(kind, context.temp_allocator),
	)
	append(&command, ..case_args(kind))

	stdin_r, stdin_w, pipe_err := os.pipe()
	if pipe_err != nil do return 0, false
	stdout_r, stdout_w, out_err := os.pipe()
	if out_err != nil {
		os.close(stdin_r); os.close(stdin_w)
		return 0, false
	}

	process, start_err := os.process_start(
		{command = command[:], stdin = stdin_r, stdout = stdout_w},
	)
	os.close(stdin_r)
	os.close(stdout_w)
	if start_err != nil {
		os.close(stdin_w); os.close(stdout_r)
		return 0, false
	}

	input := transmute([]byte)string(Input)
	for offset := 0; offset < len(input); {
		written, write_err := os.write(stdin_w, input[offset:])
		if write_err != nil || written <= 0 do break
		offset += written
	}
	os.close(stdin_w)

	marker := Frame_Marker
	frames, matched := 0, 0
	buffer: [8192]byte
	for {
		count, read_err := os.read(stdout_r, buffer[:])
		for i in 0 ..< count {
			if buffer[i] == marker[matched] {
				matched += 1
				if matched == len(marker) {
					frames += 1
					matched = 0
				}
			} else {
				matched = 1 if buffer[i] == marker[0] else 0
			}
		}
		if read_err != nil do break
	}
	os.close(stdout_r)
	state, wait_error := os.process_wait(process)
	return frames, wait_error == nil && state.success
}

main :: proc() {
	filter := os.args[1] if len(os.args) > 1 else ""
	if !os.exists(Reference) {
		fmt.eprintfln("reference binary missing: %s", Reference)
		fmt.eprintln("  tools/setup/download_ttfx.sh && third_party/ttfx/bin/build")
		os.exit(1)
	}

	fmt.printfln("%-18s %8s %8s %8s  %s", "effect", "otfx", "ttfx", "ratio", "result")
	fmt.println(strings.repeat("-", 62, context.temp_allocator))

	matches, differences, failures := 0, 0, 0
	for kind in effects.Effect_Kind {
		// Held on the heap: stepping an effect resets the temp allocator every
		// frame, which would free a temp-allocated name before it is printed.
		name := common.effect_name(kind)
		defer delete(name)
		if filter != "" && filter != name do continue

		ours, ours_ok := otfx_frames(kind)
		theirs, theirs_ok := reference_frames(kind)

		// Odin's fmt zero-pads a width-qualified integer, so counts are
		// rendered as strings to keep the columns readable.
		row :: proc(name, ours, theirs, ratio, result: string) {
			fmt.printfln("%-18s %8s %8s %8s  %s", name, ours, theirs, ratio, result)
		}
		if !ours_ok || !theirs_ok || theirs == 0 {
			row(name, fmt.tprintf("%d", ours), fmt.tprintf("%d", theirs), "-", "NO DATA")
			failures += 1
			continue
		}

		ours_text := fmt.tprintf("%d", ours)
		theirs_text := fmt.tprintf("%d", theirs)
		ratio_text := fmt.tprintf("%.3f", f64(ours) / f64(theirs))
		switch {
		case ours == theirs:
			row(name, ours_text, theirs_text, ratio_text, "match")
			matches += 1
		case:
			row(name, ours_text, theirs_text, ratio_text, "differs (diagnostic)")
			differences += 1
		}
		free_all(context.temp_allocator)
	}

	fmt.println(strings.repeat("-", 62, context.temp_allocator))
	fmt.printfln(
		"%d match, %d diagnostic differences, %d failures",
		matches,
		differences,
		failures,
	)
	if matches + differences + failures == 0 {
		fmt.eprintfln("unknown effect filter: %s", filter)
		os.exit(2)
	}
	if failures > 0 do os.exit(1)
}
