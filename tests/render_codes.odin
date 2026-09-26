package regression

import "../src/engine"
import "core:mem"
import "core:strings"
import "core:testing"

@(test)
prepared_edits_preserve_unedited_fields :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 1, 1
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("A", cfg, context.allocator)
	testing.expect_value(t, err, engine.Input_Error.None)
	id := e.particle_sets.input[0]
	visual := engine.Visual {
		symbol = "▉",
		fg     = engine.Color{1, 2, 3},
		bg     = engine.Color{4, 5, 6},
		bold   = true,
	}
	code := engine.prepare_visual(&e, visual)
	engine.set_particle(&e, id, visible = true, visual = code)
	testing.expect_value(t, engine.get_visual(&e, id), visual)
	engine.frame_build(&e)
	testing.expect_value(t, engine.get_render_visual(&e, id), visual)
	// Invalidating prepared bytes cannot lose fields or emit unchanged output.
	testing.expect_value(t, engine.get_visual(&e, id), visual)
	engine.frame_build(&e)
	expect_visible_draws(t, &e)
	engine.set_visual(&e, id, code)
	engine.set_foreground(&e, id, visual.fg)
	engine.set_symbol(&e, id, "B")
	visual.symbol = "B"
	testing.expect_value(t, engine.get_visual(&e, id), visual)
	// Returning to the last emitted appearance before emission produces no diff.
	engine.set_visual(&e, id, code)
	engine.frame_build(&e)
	expect_visible_draws(t, &e)
	engine.set_symbol(&e, id, "C")
	visual.symbol = "C"
	testing.expect_value(t, engine.get_visual(&e, id), visual)
	engine.frame_build(&e)
	testing.expect_value(t, engine.get_render_visual(&e, id), visual)
}

@(test)
bulk_visual_codes_match_ordered_scalar_updates :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	for handling in engine.Existing_Color_Handling {
		for no_color in ([]bool{false, true}) {
			cfg := engine.config_default()
			cfg.canvas_width, cfg.canvas_height = 20, 1
			cfg.ignore_terminal_dimensions = true
			cfg.existing_color_handling, cfg.no_color = handling, no_color
			a, err_a := engine.engine_make(
				"\x1b[31mABCDEFGHIJKLMNOPQ\x1b[0m",
				cfg,
				context.allocator,
			)
			b, err_b := engine.engine_make(
				"\x1b[31mABCDEFGHIJKLMNOPQ\x1b[0m",
				cfg,
				context.allocator,
			)
			testing.expect_value(t, err_a, engine.Input_Error.None)
			testing.expect_value(t, err_b, engine.Input_Error.None)
			palette: [3]engine.Visual_Id
			for visual, i in ([]engine.Visual{{symbol = "A", fg = engine.Color{1, 2, 3}}, {symbol = "▉", bg = engine.Color{255, 128, 0}, bold = true}, {symbol = "A", fg = engine.Color{9, 8, 7}}}) {
				palette[i] = engine.prepare_visual(&a, visual)
				testing.expect_value(t, palette[i], engine.prepare_visual(&b, visual))
			}
			for id in a.particle_sets.input {
				engine.set_particle(&a, id, visible = true)
				engine.set_particle(&b, id, visible = true)
			}
			ids: [65]engine.Particle_Id
			codes: [65]engine.Visual_Id
			for count in ([]int{0, 1, 7, 8, 9, 65}) {
				for phase in 0 ..< 3 {
					for i in 0 ..< count {
						// Sparse order and repeated IDs exercise ordered overwrites,
						// including a later lane restoring a prior appearance.
						ids[i] = a.particle_sets.input[((i * 7) % 5) * 3]
						codes[i] = palette[(i + phase) % 3]
					}
					engine.set_visuals(&a, ids[:count], codes[:count])
					for i in 0 ..< count do engine.set_visual(&b, ids[i], codes[i])
					engine.frame_build(&a)
					engine.frame_build(&b)
					testing.expect_value(
						t,
						string(engine.frame_bytes(&a)),
						string(engine.frame_bytes(&b)),
					)
					for id in a.particle_sets.input {
						testing.expect_value(
							t,
							engine.get_visual(&a, id),
							engine.get_visual(&b, id),
						)
					}
				}
			}
		}
	}
}

@(test)
render_codes_preserve_logical_appearance_and_transitions :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 1, 1
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("A", cfg, context.allocator)
	testing.expect_value(t, err, engine.Input_Error.None)
	id := e.particle_sets.input[0]
	engine.set_particle(&e, id, visible = true)
	code := engine.prepare_visual(&e, engine.Visual{symbol = "B"})
	engine.set_visual(&e, id, code)
	engine.frame_build(&e)
	testing.expect_value(t, frame_text(&e), "B")
	testing.expect_value(t, engine.get_visual(&e, engine.Particle_Id(id)).symbol, "B")
	// This equals the original raw visual, but differs from the current code.
	engine.set_visual(&e, id, engine.Visual{symbol = "A"})
	engine.frame_build(&e)
	testing.expect_value(t, frame_text(&e), "A")
	engine.set_visual(&e, id, code)
	engine.frame_build(&e)
	testing.expect_value(t, frame_text(&e), "B")
	// A different raw visual, then re-enter the same encoded appearance.
	engine.set_particle(&e, id, visual = engine.Visual{symbol = "C"})
	engine.frame_build(&e)
	testing.expect_value(t, frame_text(&e), "C")
	engine.set_visual(&e, id, code)
	engine.frame_build(&e)
	testing.expect_value(t, frame_text(&e), "B")
	// Direct writers obey the same invalidation contract.
	engine.set_symbol(&e, id, "D")
	engine.frame_build(&e)
	testing.expect_value(t, frame_text(&e), "D")
	engine.set_visual(&e, id, code)
	engine.set_symbol(&e, id, "E")
	engine.set_foreground(&e, id, engine.Color{1, 2, 3})
	engine.set_background(&e, id, engine.Color{4, 5, 6})
	engine.set_bold(&e, id, true)
	engine.frame_build(&e)
	testing.expect_value(
		t,
		frame_text(&e),
		"\x1b[01m\x1b[38;2;001;002;003m\x1b[48;2;004;005;006mE\x1b[0m",
	)
	engine.set_symbol(&e, id, "E")
	engine.set_foreground(&e, id, engine.Color{1, 2, 3})
	engine.frame_build(&e)
	expect_visible_draws(t, &e)
	engine.set_foreground(&e, id, nil)
	engine.set_background(&e, id, nil)
	engine.set_bold(&e, id, false)
	engine.frame_build(&e)
	testing.expect_value(t, frame_text(&e), "E")
}

@(test)
render_codes_preserve_input_color_policy :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	for handling in engine.Existing_Color_Handling {
		for mode in 0 ..< 3 {
			cfg := engine.config_default()
			cfg.canvas_width, cfg.canvas_height = 1, 1
			cfg.ignore_terminal_dimensions = true
			cfg.existing_color_handling = handling
			cfg.no_color, cfg.xterm_colors = mode == 1, mode == 2
			coded, code_err := engine.engine_make("\x1b[1;31;44mA", cfg, context.allocator)
			raw, raw_err := engine.engine_make("\x1b[1;31;44mA", cfg, context.allocator)
			testing.expect_value(t, code_err, engine.Input_Error.None)
			testing.expect_value(t, raw_err, engine.Input_Error.None)
			visual := engine.Visual {
				symbol = "▉",
				fg     = engine.Color{1, 90, 255},
			}
			code_id, raw_id := coded.particle_sets.input[0], raw.particle_sets.input[0]
			engine.set_particle(&coded, code_id, visible = true)
			engine.set_particle(&raw, raw_id, visible = true, visual = visual)
			engine.set_visual(&coded, code_id, engine.prepare_visual(&coded, visual))
			engine.frame_build(&coded)
			engine.frame_build(&raw)
			testing.expect_value(
				t,
				string(engine.frame_bytes(&coded)),
				string(engine.frame_bytes(&raw)),
			)
			testing.expect_value(
				t,
				engine.get_visual(&coded, engine.Particle_Id(code_id)).symbol,
				visual.symbol,
			)
		}
	}
}

@(test)
appearance_packet_survives_placement_changes :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, mem.dynamic_arena_allocator(&arena))
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	for handling in engine.Existing_Color_Handling {
		for prepared in ([]bool{false, true}) {
			cfg := engine.config_default()
			cfg.canvas_width, cfg.canvas_height = 2, 1
			cfg.ignore_terminal_dimensions = true
			cfg.existing_color_handling = handling
			e, err := engine.engine_make("\x1b[1;31mA", cfg, context.allocator)
			testing.expect_value(t, err, engine.Input_Error.None)
			id := e.particle_sets.input[0]
			visual := engine.Visual {
				symbol = "B",
				fg     = engine.Color{1, 2, 3},
			}
			if prepared {
				code := engine.prepare_visual(&e, visual)
				testing.expect_value(t, engine.prepare_visual(&e, visual), code)
				engine.set_particle(&e, id, visual = code, visible = true)
			} else {
				engine.set_particle(&e, id, visual = visual, visible = true)
			}
			builder := strings.builder_make(0, 64)
			engine.write_particle(&e, id, &builder)
			expected := without_nul(strings.to_string(builder))
			// Writing a preview must not claim the bytes reached the terminal.
			testing.expect_value(t, engine.get_render_visual(&e, id).symbol, visual.symbol)
			engine.frame_build(&e)
			bytes := transmute([]byte)frame_text(&e)
			testing.expect_value(t, string(bytes[:len(expected)]), expected)
			testing.expect_value(t, string(bytes[len(expected):]), " ")
			cached_visual := engine.get_visual(&e, id)
			allocations := track.total_allocation_count
			entries := len(e.visuals)
			for tick in 0 ..< 20 {
				engine.set_particle(
					&e,
					id,
					coord = engine.Coord{1 + tick % 2, 1},
					layer = tick,
					visible = tick % 3 != 0,
				)
				testing.expect_value(
					t,
					engine.get_visual(&e, id),
					cached_visual,
				)
				engine.frame_build(&e)
				strings.builder_reset(&builder)
				engine.write_particle(&e, id, &builder)
				testing.expect_value(t, without_nul(strings.to_string(builder)), expected)
			}
			engine.set_symbol(&e, id, "C")
			testing.expect_value(
				t,
				engine.get_visual(&e, id).fg,
				cached_visual.fg,
			)
			strings.builder_reset(&builder)
			engine.write_particle(&e, id, &builder)
			testing.expect(t, strings.contains(strings.to_string(builder), "C"))
			engine.set_symbol(&e, id, "C")
			// Dynamic appearances use bounded character storage, not runtime interning.
			testing.expect_value(t, len(e.visuals), entries)
			testing.expect_value(t, track.total_allocation_count, allocations)
		}
	}
}

// Byte-exact assertions below ignore only the terminal's NUL fill character.
// The row-slot tests check the padding and fixed offsets themselves.
without_nul :: proc(s: string) -> string {
	b := strings.builder_make(0, len(s), context.temp_allocator)
	for byte in s do if byte != 0 do strings.write_rune(&b, byte)
	return strings.to_string(b)
}

frame_text :: proc(e: ^engine.Engine) -> string {
	return without_nul(string(engine.frame_bytes(e)))
}
