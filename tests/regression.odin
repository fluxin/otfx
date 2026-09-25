package regression

import effects "../src/effects"
import engine "../src/engine"
import common "../tools/common"
import "core:mem"
import "core:strings"
import "core:testing"

@(test)
cropped_anchors :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	for anchor in ([]engine.Anchor{.N, .Ne, .E, .Se, .C}) {
		cfg := engine.config_default()
		cfg.canvas_width, cfg.canvas_height = 2, 1
		cfg.ignore_terminal_dimensions = true
		cfg.anchor_text = anchor
		e, err := engine.engine_make("hello\nworld", cfg, context.allocator)
		testing.expect(t, err == .None)
		testing.expect_value(t, len(e.character_sets.input), 2)
		for id in e.character_sets.input do testing.expect(t, engine.canvas_in(e.canvas, e.chars.input_coord[id]))
	}
}

@(test)
wrapped_cells_and_storage :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, mem.dynamic_arena_allocator(&arena))
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 2, 7
	cfg.ignore_terminal_dimensions, cfg.wrap_text = true, true
	e, err := engine.engine_make("\x1b[31mABCD\n\nEFG", cfg, context.allocator)
	testing.expect(t, err == .None)
	expected := []engine.Coord{{1, 5}, {2, 5}, {1, 4}, {2, 4}, {1, 2}, {2, 2}, {1, 1}}
	testing.expect_value(t, len(e.character_sets.input), len(expected))
	for id, i in e.character_sets.input {
		testing.expect_value(t, e.chars.input_coord[id], expected[i])
		testing.expect(t, e.chars.input_style[id].fg != nil)
	}
	cfg.canvas_width, cfg.canvas_height = 80, 24
	input := strings.repeat("x", 64_000)
	before := track.total_memory_allocated
	large, large_err := engine.engine_make(input, cfg, context.allocator)
	testing.expect(t, large_err == .None)
	testing.expect_value(t, len(large.character_sets.input), 80 * 24)
	testing.expect(
		t,
		track.total_memory_allocated - before < 64 * 1024 * 1024,
		"wrapping must not retain quadratic copies of line suffixes",
	)
}

@(test)
render_dirty_appearance :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	for no_color in ([]bool{false, true}) {
		cfg := engine.config_default()
		cfg.ignore_terminal_dimensions, cfg.no_color = true, no_color
		e, err := engine.engine_make("hello", cfg, context.allocator)
		testing.expect(t, err == .None)
		for id in e.character_sets.input do e.chars.is_visible[id] = true
		engine.frame_build_all(&e)
		testing.expect_value(t, string(e.out_buf[:]), "hello")
		engine.frame_build_all(&e)
		testing.expect_value(t, len(e.out_buf), 0)
		id := e.character_sets.input[0]
		e.chars.visual[id].fg = engine.Color{255, 0, 0}
		engine.frame_build_all(&e)
		testing.expect_value(t, len(e.out_buf) == 0, no_color)
		e.chars.visual[id].symbol = "X"
		engine.frame_build_all(&e)
		testing.expect(t, strings.contains(string(e.out_buf[:]), "X"))
		e.chars.is_visible[id] = false
		engine.frame_build_all(&e)
		testing.expect_value(t, string(e.out_buf[:]), " ")
	}
}

@(test)
typed_input_errors :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	inputs := []string {
		"\x1b",
		"\x1b\n",
		"\x1b7",
		"\x1b]0;title\x07",
		"\x1b]0;title\x1b\\",
		"\x1b]unterminated",
		"\x1b[",
		"\x1b[123",
		"\x1b[2JX",
		"\x1b[38;5;999mX",
	}
	errors := []engine.Input_Error {
		.Unsupported_Escape,
		.Unsupported_Escape,
		.Unsupported_Escape,
		.Unsupported_Escape,
		.Unsupported_Escape,
		.Unsupported_Escape,
		.Unsupported_Cursor,
		.Unsupported_Cursor,
		.Unsupported_Cursor,
		.Unsupported_SGR,
	}
	cfg := engine.config_default()
	for input, i in inputs {
		_, err := engine.engine_make(input, cfg, context.allocator)
		testing.expect_value(t, err, errors[i])
	}
	cfg.tab_width = 0
	_, err := engine.engine_make("\tX", cfg, context.allocator)
	testing.expect(t, err == .Invalid_Tab_Width)
}

@(test)
render_painter_creation_order :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("A  B", cfg, context.allocator)
	testing.expect(t, err == .None)
	a, b := e.character_sets.input[0], e.character_sets.input[1]
	fill := e.character_sets.inner_fill[0]
	added := engine.add_character(&e, "X", {1, 1})
	ids := []engine.Char_Id{added, fill, b, a}
	for id in ids {
		e.chars.is_visible[id] = true
		e.chars.current_coord[id] = {1, 1}
	}
	// Selection order must not decide equal-layer collisions. Spaces between
	// input glyphs, fills and added glyphs all retain creation-order priority.
	engine.update_render_cells_selected(&e, ids)
	testing.expect_value(t, e.render_cells[0], i32(added))
	engine.update_render_cells_all(&e)
	testing.expect_value(t, e.render_cells[0], i32(added))
	e.chars.is_visible[added] = false
	engine.update_render_cells_selected(&e, ids)
	testing.expect_value(t, e.render_cells[0], i32(fill))
	e.chars.is_visible[fill] = false
	engine.update_render_cells_selected(&e, ids)
	testing.expect_value(t, e.render_cells[0], i32(b))
	e.chars.layer[a] = 1
	engine.update_render_cells_selected(&e, ids)
	testing.expect_value(t, e.render_cells[0], i32(a))
	engine.update_render_cells_all(&e)
	testing.expect_value(t, e.render_cells[0], i32(a))
}

@(test)
layout_resize_contract :: proc(t: ^testing.T) {
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 4, 2
	widths := []int{9, 0, 3}
	// An even 4x2 canvas inside a 9x7 terminal exercises odd centre rounding.
	offsets := [engine.Anchor]engine.Coord {
		.N  = {2, 5},
		.Ne = {5, 5},
		.E  = {5, 2},
		.Se = {5, 0},
		.S  = {2, 0},
		.Sw = {0, 0},
		.W  = {0, 2},
		.Nw = {0, 5},
		.C  = {2, 2},
	}
	for anchor in engine.Anchor {
		cfg.anchor_canvas = anchor
		canvas, layout := engine.layout_make(cfg, widths, 9, 7)
		p := offsets[anchor]
		testing.expect_value(t, canvas.width, 4)
		testing.expect_value(t, canvas.height, 2)
		testing.expect_value(
			t,
			layout,
			engine.Render_Layout {
				p.row + 2,
				p.row + 1,
				p.column + 4,
				p.column + 1,
				p.column,
				p.row,
			},
		)
		e := engine.Engine {
			cfg    = cfg,
			canvas = canvas,
			layout = layout,
		}
		append(&e.input_line_widths, ..widths)
		testing.expect(t, !engine.resize_layout_changed(&e, 9, 7))
		testing.expect_value(t, engine.resize_layout_changed(&e, 11, 9), anchor != .Sw)
		delete(e.input_line_widths)
	}
	cfg.anchor_canvas = .C
	cfg.canvas_width, cfg.canvas_height = 12, 10
	_, cropped := engine.layout_make(cfg, widths, 9, 7)
	testing.expect_value(t, cropped, engine.Render_Layout{7, 1, 9, 1, -2, -2})
	cfg.canvas_width, cfg.canvas_height, cfg.wrap_text = -1, -1, true
	canvas, _ := engine.layout_make(cfg, widths, 4, 10)
	testing.expect_value(t, canvas.width, 4)
	testing.expect_value(t, canvas.height, 5) // three wrapped rows, blank, short row
	cfg.ignore_terminal_dimensions = true
	unclipped: engine.Render_Layout
	canvas, unclipped = engine.layout_make(cfg, widths, 4, 10)
	testing.expect_value(t, canvas.width, 9)
	testing.expect_value(t, canvas.height, 3)
	testing.expect_value(t, unclipped, engine.Render_Layout{3, 1, 9, 1, 0, 0})
	cfg.canvas_width, cfg.canvas_height = 0, 0
	canvas, _ = engine.layout_make(cfg, widths, 4, 10)
	testing.expect_value(t, canvas.width, 4)
	testing.expect_value(t, canvas.height, 10)
}

@(test)
option_domains_and_lists :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	for args in ([][]string{{"--wipe-delay", "-1"}, {"--final-gradient-frames", "0"}, {"--final-gradient-steps", "12", "0"}, {"--final-gradient-stops", ""}}) {
		_, ok := effects.make_effect(.Wipe, args)
		testing.expect(t, !ok)
	}
	for value in ([]string{"0", "-1", "NaN", "Inf"}) {
		_, ok := effects.make_effect(.Slide, []string{"--movement-speed", value})
		testing.expect(t, !ok)
	}
	_, zero_delay_ok := effects.make_effect(.Wipe, []string{"--wipe-delay", "0"})
	testing.expect(t, zero_delay_ok)
	cfg := effects.wipe_config_default()
	testing.expect(
		t,
		effects.wipe_parse(
			&cfg,
			[]string {
				"--final-gradient-stops",
				"ff0000",
				"00ff00",
				"--final-gradient-steps=2",
				"3",
				"--wipe-delay",
				"0",
			},
		),
	)
	testing.expect_value(t, len(cfg.final_gradient_stops), 2)
	testing.expect_value(t, cfg.final_gradient_steps[1], 3)
	testing.expect_value(t, cfg.wipe_delay, 0)
	quoted := effects.wipe_config_default()
	testing.expect(
		t,
		effects.wipe_parse(&quoted, []string{"--final-gradient-stops", "ff0000 00ff00"}),
	)
	testing.expect_value(t, quoted.final_gradient_stops[1], cfg.final_gradient_stops[1])
	waves := effects.waves_config_default()
	testing.expect(
		t,
		effects.waves_parse(
			&waves,
			[]string{"--wave-symbols", ".", "-", "*", "--wave-count", "1"},
		),
	)
	testing.expect_value(t, len(waves.wave_symbols), 3)
	// Parsed strings must remain valid when parser scratch is reclaimed.
	free_all(context.temp_allocator)
	testing.expect_value(t, waves.wave_symbols[1], "-")
}

@(test)
overshooting_wipe_completes :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.frame_rate = 0
	cfg.ignore_terminal_dimensions = true
	for easing in ([]string{"IN_BACK", "OUT_BACK", "IN_OUT_BACK", "IN_ELASTIC", "OUT_ELASTIC", "IN_OUT_ELASTIC"}) {
		run, ok := common.run_make(.Wipe, []string{"--wipe-ease", easing}, cfg, "hello\nworld", 1)
		testing.expect(t, ok)
		frames := 0
		for frames < 2000 {
			_, _, produced := common.run_step(&run)
			if !produced do break
			frames += 1
			free_all(context.temp_allocator)
		}
		testing.expect(t, frames < 2000)
		for id in run.engine_state.character_sets.input do testing.expect(t, run.engine_state.chars.is_visible[id])
	}
}

@(test)
rings_disperse_reuses_storage :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, mem.dynamic_arena_allocator(&arena))
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 80, 24
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make(
		"Hello, World!\nThis is otfx.\nOdin vs Rust",
		cfg,
		context.allocator,
	)
	testing.expect(t, err == .None)
	state := effects.Rings_State {
		config = effects.rings_config_default(),
	}
	effects.rings_build(&state, &e)
	before := track.total_allocation_count
	for i in 0 ..< 3 do effects.rings_begin_disperse(&state, &e, i == 0)
	testing.expect_value(t, track.total_allocation_count, before)
}
