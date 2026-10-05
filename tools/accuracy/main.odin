package main

import "../../src/engine"
import "../common"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

// Capture real renderer cells for cross-language appearance review. Separate from
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
	if !known {
		fmt.eprintfln("unknown effect: %s", name)
		os.exit(1)
	}
	input, err := os.read_entire_file(input_path, context.allocator)
	if err != nil {
		fmt.eprintfln("failed to read %s: %v", input_path, err)
		os.exit(1)
	}
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
		if !ok {
			fmt.eprintln("failed to construct effect run")
			os.exit(1)
		}
		frames := 0
		for tick := 0;; tick += 1 {
			width, height, alive := common.run_step(&run)
			_ = height
			if !alive do break
			if tick >= 20_000 {
				fmt.eprintfln("%s exceeded 20000 frames", name)
				os.exit(1)
			}
			frames += 1
			if pass == 0 {
				result.total += 1
			} else {
				wanted := false
				for i in 0 ..< 12 do wanted ||= tick == i * max(result.total - 1, 0) / 11
				if wanted {
					context.allocator = base_allocator
					snapshot := Snapshot {
						tick = tick,
					}
					e := &run.engine_state
					for entry, cell in e.cells {
						id := entry.top
						if id == engine.NO_PARTICLE do continue
						v := engine.get_render_appearance(e, engine.Particle_Id(id))
						sym := e.particles.symbol[id]
						c := Cell {
							x      = cell % width,
							y      = cell / width,
							symbol = fmt.aprintf("%c", sym) if sym != 0 else "",
						}
						if color, set := v.colors.fg.?; set do c.fg = fmt.aprintf("#%02x%02x%02x", color.r, color.g, color.b)
						if color, set := v.colors.bg.?; set do c.bg = fmt.aprintf("#%02x%02x%02x", color.r, color.g, color.b)
						append(&snapshot.cells, c)
					}
					append(&result.frames, snapshot)
					context.allocator = mem.dynamic_arena_allocator(&arena)
				}
			}
			free_all(context.temp_allocator)
		}
		if pass == 1 && frames != result.total {
			fmt.eprintln("seeded Odin replay changed duration")
			os.exit(1)
		}
		context.allocator = base_allocator
		mem.dynamic_arena_destroy(&arena)
	}
	encoded, json_err := json.marshal(result)
	if json_err != nil {
		fmt.eprintfln("failed to marshal json: %v", json_err)
		os.exit(1)
	}
	defer delete(encoded)
	if write_err := os.write_entire_file(output_path, encoded); write_err != nil {
		fmt.eprintfln("failed to write %s: %v", output_path, write_err)
		os.exit(1)
	}
	fmt.printf("%s: %d frames\n", name, result.total)
}
