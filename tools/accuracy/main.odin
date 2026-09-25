package main

import "../../src/engine"
import "../common"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

// Capture real renderer cells for cross-language visual review. Separate from
// the product: no effect can write a review-only frame or bypass its renderer.
Cell :: struct {
	x, y:           int,
	symbol, fg, bg: string,
}
Snapshot :: struct {
	tick:  int,
	cells: [dynamic]Cell,
}
Capture :: struct {
	effect: string,
	total:  int,
	frames: [dynamic]Snapshot,
}

main :: proc() {
	if len(os.args) < 4 {
		fmt.eprintln("usage: accuracy effect input-file output.json [effect-options...]")
		os.exit(1)
	}
	name, input_path, output_path := os.args[1], os.args[2], os.args[3]
	kind, known := common.effect_kind_from_name(name)
	assert(known)
	input, err := os.read_entire_file(input_path, context.allocator)
	assert(err == nil)
	defer delete(input)
	text := strings.trim_right(string(input), "\n")
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 84, 13
	cfg.anchor_canvas, cfg.anchor_text = .C, .C
	cfg.frame_rate = 0
	cfg.ignore_terminal_dimensions, cfg.virtual_clock = true, true
	result := Capture {
		effect = name,
	}
	for pass in 0 ..< 2 {
		arena: mem.Dynamic_Arena
		mem.dynamic_arena_init(&arena)
		base_allocator := context.allocator
		context.allocator = mem.dynamic_arena_allocator(&arena)
		run, ok := common.run_make(kind, os.args[4:], cfg, text, 3)
		assert(ok)
		frames := 0
		for tick := 0;; tick += 1 {
			width, height, alive := common.run_step(&run)
			if !alive do break
			assert(tick < 20_000)
			frames += 1
			if pass == 0 {
				result.total += 1
			} else {
				wanted := false
				for i in 0 ..< 12 do wanted ||= tick == i * (result.total - 1) / 11
				if wanted {
					context.allocator = base_allocator
					snapshot := Snapshot {
						tick = tick,
					}
					e := &run.engine_state
					for id, cell in e.render_cells[:width * height] {
						if id < 0 do continue
						v := engine.effective_visual(
							e.chars.visual[id],
							e.chars.input_style[id],
							e.chars.uses_input_preexisting_colors[id],
							cfg.existing_color_handling,
						)
						c := Cell {
							x      = cell % width,
							y      = height - 1 - cell / width,
							symbol = v.symbol,
						}
						// Copy symbols: the run arena is released after this pass.
						c.symbol = strings.clone(c.symbol)
						if color, set := v.fg.?; set do c.fg = fmt.aprintf("#%02x%02x%02x", color.r, color.g, color.b)
						if color, set := v.bg.?; set do c.bg = fmt.aprintf("#%02x%02x%02x", color.r, color.g, color.b)
						append(&snapshot.cells, c)
					}
					append(&result.frames, snapshot)
					context.allocator = mem.dynamic_arena_allocator(&arena)
				}
			}
			free_all(context.temp_allocator)
		}
		if pass == 1 do assert(frames == result.total, "seeded Odin replay changed duration")
		context.allocator = base_allocator
		mem.dynamic_arena_destroy(&arena)
	}
	encoded, json_err := json.marshal(result)
	assert(json_err == nil)
	assert(os.write_entire_file(output_path, encoded) == nil)
	fmt.printf("%s: %d frames\n", name, result.total)
}
