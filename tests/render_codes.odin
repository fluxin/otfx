package regression

import "../src/engine"
import "core:mem"
import "core:strings"
import "core:testing"

@(test)
particle_constructor_rejects_surrogate :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 1, 1
	cfg.ignore_terminal_dimensions = true
	e, _ := engine.engine_make("A", cfg)
	testing.expect_assert(t, "symbol must be a valid Unicode scalar value")
	engine.add_particle(
		&e,
		rune(0xd800),
		engine.prepare_appearance(&e, engine.Appearance{}),
		{1, 1},
	)
}

@(test)
symbol_setter_rejects_out_of_range_rune :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 1, 1
	cfg.ignore_terminal_dimensions = true
	e, _ := engine.engine_make("A", cfg)
	testing.expect_assert(t, "symbol must be a valid Unicode scalar value")
	engine.set_symbol(&e, e.particle_sets.input[0], rune(0x110000))
}

@(test)
private_appearance_edits_leave_shared_appearances_unchanged :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 2, 1
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("AB", cfg)
	testing.expect_value(t, err, engine.Input_Error.None)
	shared := engine.Appearance {
		colors = {fg = engine.Color{255, 0, 0}},
	}
	code := engine.prepare_appearance(&e, shared)
	other := engine.prepare_appearance(&e, shared)
	testing.expect(t, code != other)
	entries := len(e.shared_appearances)
	first := engine.add_particle(&e, 'X', code, {1, 1})
	second := engine.add_particle(&e, 'Q', code, {2, 1})
	testing.expect_value(t, len(e.shared_appearances), entries)
	for id in ([]engine.Particle_Id{first, second}) {
		testing.expect_value(t, e.particles[id].initial_appearance_id, code)
		testing.expect_value(t, e.particles[id].shared_appearance_id, code)
		expect_appearance(t, engine.get_appearance(&e, id), shared)
		engine.set_particle(&e, id, engine.Visible(true))
	}
	engine.set_foreground(&e, first, engine.Color{0, 0, 255})
	engine.set_background(&e, first, engine.Color{1, 2, 3})
	engine.compose_frame(&e)
	expected := shared
	expected.colors = {
		fg = engine.Color{0, 0, 255},
		bg = engine.Color{1, 2, 3},
	}
	expect_appearance(t, engine.get_appearance(&e, first), expected)
	expect_appearance(t, engine.get_appearance(&e, second), shared)
	testing.expect_value(t, e.particles[first].shared_appearance_id, engine.NO_APPEARANCE)
	testing.expect_value(t, e.particles[second].shared_appearance_id, code)
	expect_appearance(t, e.shared_appearances[code - 1], shared)
	testing.expect_value(t, e.particles[first].initial_appearance_id, code)
	expect_appearance(t, engine.get_initial_appearance(&e, first), shared)
	engine.frame_build(&e)
	expect_frame_cell(t, &e, 0, 0, 'X', expected)
	expect_frame_cell(t, &e, 1, 0, 'Q', shared)
	// Reselecting shared discards the private override, including its background.
	engine.set_appearance(&e, first, code)
	engine.set_symbol(&e, first, 'Y')
	engine.compose_frame(&e)
	expected = shared
	testing.expect_value(t, e.particles[first].shared_appearance_id, code)
	testing.expect_value(t, e.particles[first].symbol, 'Y')
	testing.expect_value(t, e.particles[second].symbol, 'Q')
	expect_appearance(t, engine.get_appearance(&e, first), expected)
	expect_appearance(t, engine.get_appearance(&e, second), shared)
	engine.frame_build(&e)
	expect_frame_cell(t, &e, 0, 0, 'Y', expected)
	expect_frame_cell(t, &e, 1, 0, 'Q', shared)
}

@(test)
prepared_edits_preserve_unedited_fields :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 1, 1
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("A", cfg)
	testing.expect_value(t, err, engine.Input_Error.None)
	id := e.particle_sets.input[0]
	appearance_symbol := '▉'
	engine.set_symbol(&e, id, appearance_symbol)
	appearance := engine.Appearance {
		bold = true,
		colors = {fg = engine.Color{1, 2, 3}, bg = engine.Color{4, 5, 6}},
	}
	code := engine.prepare_appearance(&e, appearance)
	engine.set_particle(&e, id, engine.Visible(true))
	engine.set_appearance(&e, id, code)
	engine.compose_frame(&e)
	expect_appearance(t, engine.get_appearance(&e, id), appearance)
	engine.frame_build(&e)
	expect_appearance(t, engine.get_render_appearance(&e, id)^, appearance)
	// Invalidating prepared bytes cannot lose fields or emit unchanged output.
	expect_appearance(t, engine.get_appearance(&e, id), appearance)
	engine.frame_build(&e)
	expect_visible_draws(t, &e)
	engine.set_appearance(&e, id, code)
	engine.set_foreground(&e, id, appearance.colors.fg)
	engine.set_symbol(&e, id, 'B')
	engine.compose_frame(&e)
	testing.expect_value(t, e.particles[id].symbol, 'B')
	expect_appearance(t, engine.get_appearance(&e, id), appearance)
	// Returning to the last emitted appearance before emission produces no diff.
	engine.set_appearance(&e, id, code)
	engine.frame_build(&e)
	expect_visible_draws(t, &e)
	engine.set_symbol(&e, id, 'C')
	engine.compose_frame(&e)
	testing.expect_value(t, e.particles[id].symbol, 'C')
	expect_appearance(t, engine.get_appearance(&e, id), appearance)
	engine.frame_build(&e)
	expect_appearance(t, engine.get_render_appearance(&e, id)^, appearance)
}

@(test)
bulk_appearance_codes_match_ordered_scalar_updates :: proc(t: ^testing.T) {
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
			a, err_a := engine.engine_make("\x1b[31mABCDEFGHIJKLMNOPQ\x1b[0m", cfg)
			b, err_b := engine.engine_make("\x1b[31mABCDEFGHIJKLMNOPQ\x1b[0m", cfg)
			testing.expect_value(t, err_a, engine.Input_Error.None)
			testing.expect_value(t, err_b, engine.Input_Error.None)
			palette: [3]engine.Appearance_Id
			for appearance, i in ([]engine.Appearance{{colors = {fg = engine.Color{1, 2, 3}}}, {bold = true, colors = {bg = engine.Color{255, 128, 0}}}, {colors = {fg = engine.Color{9, 8, 7}}}}) {
				palette[i] = engine.prepare_appearance(&a, appearance)
				testing.expect_value(t, palette[i], engine.prepare_appearance(&b, appearance))
			}
			for id in a.particle_sets.input {
				engine.set_particle(&a, id, engine.Visible(true))
				engine.set_particle(&b, id, engine.Visible(true))
			}
			ids: [65]engine.Particle_Id
			codes: [65]engine.Appearance_Id
			for count in ([]int{0, 1, 7, 8, 9, 65}) {
				for phase in 0 ..< 3 {
					for i in 0 ..< count {
						// Sparse order and repeated IDs exercise ordered overwrites,
						// including a later lane restoring a prior appearance.
						ids[i] = a.particle_sets.input[((i * 7) % 5) * 3]
						codes[i] = palette[(i + phase) % 3]
					}
					engine.set_appearances(&a, ids[:count], codes[:count])
					for i in 0 ..< count do engine.set_appearance(&b, ids[i], codes[i])
					engine.frame_build(&a)
					engine.frame_build(&b)
					testing.expect_value(
						t,
						string(frame_without_padding(&a)),
						string(frame_without_padding(&b)),
					)
					for id in a.particle_sets.input {
						expect_appearance(
							t,
							engine.get_appearance(&a, id),
							engine.get_appearance(&b, id),
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
	e, err := engine.engine_make("A", cfg)
	testing.expect_value(t, err, engine.Input_Error.None)
	id := e.particle_sets.input[0]
	engine.set_particle(&e, id, engine.Visible(true))
	code := engine.prepare_appearance(&e, engine.Appearance{})
	engine.set_symbol(&e, id, 'B')
	engine.set_appearance(&e, id, code)
	engine.frame_build(&e)
	testing.expect_value(t, string(frame_without_padding(&e)), "B")
	testing.expect_value(t, e.particles.symbol[engine.Particle_Id(id)], 'B')
	// This equals the original raw appearance, but differs from the current code.
	engine.set_symbol(&e, id, 'A')
	engine.set_appearance(&e, id, engine.Appearance{})
	engine.frame_build(&e)
	testing.expect_value(t, string(frame_without_padding(&e)), "A")
	engine.set_symbol(&e, id, 'B')
	engine.set_appearance(&e, id, code)
	engine.frame_build(&e)
	testing.expect_value(t, string(frame_without_padding(&e)), "B")
	// A different raw appearance, then re-enter the same encoded appearance.
	engine.set_symbol(&e, id, 'C')
	engine.set_appearance(&e, id, engine.Appearance{})
	engine.frame_build(&e)
	testing.expect_value(t, string(frame_without_padding(&e)), "C")
	engine.set_symbol(&e, id, 'B')
	engine.set_appearance(&e, id, code)
	engine.frame_build(&e)
	testing.expect_value(t, string(frame_without_padding(&e)), "B")
	// Direct writers obey the same invalidation contract.
	engine.set_symbol(&e, id, 'D')
	engine.frame_build(&e)
	testing.expect_value(t, string(frame_without_padding(&e)), "D")
	engine.set_symbol(&e, id, 'B')
	engine.set_appearance(&e, id, code)
	engine.set_symbol(&e, id, 'E')
	engine.set_foreground(&e, id, engine.Color{1, 2, 3})
	engine.set_background(&e, id, engine.Color{4, 5, 6})
	engine.set_bold(&e, id, true)
	engine.frame_build(&e)
	testing.expect_value(
		t,
		string(frame_without_padding(&e)),
		"\x1b[01m\x1b[38;2;001;002;003m\x1b[48;2;004;005;006mE\x1b[0m",
	)
	engine.set_symbol(&e, id, 'E')
	engine.set_foreground(&e, id, engine.Color{1, 2, 3})
	engine.frame_build(&e)
	expect_visible_draws(t, &e)
	engine.set_foreground(&e, id, nil)
	engine.set_background(&e, id, nil)
	engine.set_bold(&e, id, false)
	engine.frame_build(&e)
	testing.expect_value(t, string(frame_without_padding(&e)), "E")
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
			coded, code_err := engine.engine_make("\x1b[1;31;44mA", cfg)
			raw, raw_err := engine.engine_make("\x1b[1;31;44mA", cfg)
			testing.expect_value(t, code_err, engine.Input_Error.None)
			testing.expect_value(t, raw_err, engine.Input_Error.None)
			appearance_symbol := '▉'
			appearance := engine.Appearance {
				colors = {fg = engine.Color{1, 90, 255}},
			}
			code_id, raw_id := coded.particle_sets.input[0], raw.particle_sets.input[0]
			engine.set_particle(&coded, code_id, engine.Visible(true))
			engine.set_particle(&raw, raw_id, engine.Visible(true))
			engine.set_symbol(&raw, raw_id, appearance_symbol)
			engine.set_symbol(&coded, code_id, appearance_symbol)
			engine.set_appearance(&raw, raw_id, appearance)
			engine.set_appearance(&coded, code_id, engine.prepare_appearance(&coded, appearance))
			engine.frame_build(&coded)
			engine.frame_build(&raw)
			testing.expect_value(
				t,
				string(frame_without_padding(&coded)),
				string(frame_without_padding(&raw)),
			)
			testing.expect_value(
				t,
				coded.particles.symbol[engine.Particle_Id(code_id)],
				appearance_symbol,
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
			e, err := engine.engine_make("\x1b[1;31mA", cfg)
			testing.expect_value(t, err, engine.Input_Error.None)
			id := e.particle_sets.input[0]
			appearance_symbol := 'B'
			engine.set_symbol(&e, id, appearance_symbol)
			appearance := engine.Appearance {
				colors = {fg = engine.Color{1, 2, 3}},
			}
			if prepared {
				code := engine.prepare_appearance(&e, appearance)
				testing.expect(t, engine.prepare_appearance(&e, appearance) != code)
				engine.set_particle(&e, id, engine.Visible(true))
				engine.set_appearance(&e, id, code)
			} else {
				engine.set_particle(&e, id, engine.Visible(true))
				engine.set_appearance(&e, id, appearance)
			}
			engine.compose_frame(&e)
			builder := strings.builder_make(0, 64)
			engine.write_particle(&e, id, &builder)
			expected := strings.clone(strings.to_string(builder))
			// Writing a preview must not claim the bytes reached the terminal.
			testing.expect_value(t, e.particles.symbol[id], appearance_symbol)
			engine.frame_build(&e)
			bytes := frame_without_padding(&e)
			testing.expect_value(t, string(bytes[:len(expected)]), expected)
			testing.expect_value(t, string(bytes[len(expected):]), " ")
			saved_cells: [102]byte
			allocations := track.total_allocation_count
			entries := len(e.shared_appearances)
			for tick in 0 ..< 20 {
				copy(saved_cells[:], e.canvas_bytes)
				engine.set_particle(
					&e,
					id,
					coord = engine.Coord{1 + tick % 2, 1},
					layer = tick,
					visible = tick % 3 != 0,
				)
				testing.expect_value(t, string(e.canvas_bytes), string(saved_cells[:]))
				engine.frame_build(&e)
				strings.builder_reset(&builder)
				engine.write_particle(&e, id, &builder)
				testing.expect_value(t, strings.to_string(builder), expected)
			}
			copy(saved_cells[:], e.canvas_bytes)
			engine.set_symbol(&e, id, 'C')
			testing.expect_value(t, string(e.canvas_bytes), string(saved_cells[:]))
			engine.compose_frame(&e)
			strings.builder_reset(&builder)
			engine.write_particle(&e, id, &builder)
			testing.expect(t, strings.contains(strings.to_string(builder), "C"))
			engine.set_symbol(&e, id, 'C')
			// Dynamic appearances use bounded character storage, not runtime interning.
			testing.expect_value(t, len(e.shared_appearances), entries)
			testing.expect_value(t, track.total_allocation_count, allocations)
		}
	}
}
