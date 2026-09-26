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
		e, err := engine.engine_make("hello\nworld", cfg)
		testing.expect(t, err == .None)
		testing.expect_value(t, len(e.particle_sets.input), 2)
		for id in e.particle_sets.input do testing.expect(t, engine.canvas_in(e.canvas, e.particles.initial_coord[id]))
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
	e, err := engine.engine_make("\x1b[31mABCD\n\nEFG", cfg)
	testing.expect(t, err == .None)
	expected := []engine.Coord{{1, 5}, {2, 5}, {1, 4}, {2, 4}, {1, 2}, {2, 2}, {1, 1}}
	testing.expect_value(t, len(e.particle_sets.input), len(expected))
	for id, i in e.particle_sets.input {
		testing.expect_value(t, e.particles.initial_coord[id], expected[i])
		testing.expect(
			t,
			engine.get_initial_appearance(&e, engine.Particle_Id(id)).colors.fg != nil,
		)
	}
	cfg.canvas_width, cfg.canvas_height = 80, 24
	input := strings.repeat("x", 64_000)
	before := track.total_memory_allocated
	large, large_err := engine.engine_make(input, cfg)
	testing.expect(t, large_err == .None)
	testing.expect_value(t, len(large.particle_sets.input), 80 * 24)
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
		e, err := engine.engine_make("hello", cfg)
		testing.expect(t, err == .None)
		for id in e.particle_sets.input do e.particles.flags[id] += {.Visible}
		engine.frame_build(&e)
		testing.expect_value(t, string(frame_without_padding(&e)), "hello")
		engine.frame_build(&e)
		testing.expect_value(t, len(frame_without_padding(&e)), 0)
		id := e.particle_sets.input[0]
		engine.set_foreground(&e, engine.Particle_Id(id), engine.Color{255, 0, 0})
		engine.frame_build(&e)
		expect_visible_draws(t, &e)
		engine.set_symbol(&e, engine.Particle_Id(id), 'X')
		engine.frame_build(&e)
		testing.expect(t, strings.contains(string(frame_without_padding(&e)), "X"))
		engine.set_particle(&e, id, engine.Visible(false))
		engine.frame_build(&e)
		testing.expect_value(t, string(frame_without_padding(&e)), " ello")
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
		_, err := engine.engine_make(input, cfg)
		testing.expect_value(t, err, errors[i])
	}
	cfg.tab_width = 0
	_, err := engine.engine_make("\tX", cfg)
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
	e, err := engine.engine_make("A  B", cfg)
	testing.expect(t, err == .None)
	a, b := e.particle_sets.input[0], e.particle_sets.input[1]
	fill := e.particle_sets.inner_fill[0]
	added := engine.add_particle(
		&e,
		'X',
		engine.prepare_appearance(&e, engine.Appearance{}),
		{1, 1},
	)
	ids := []engine.Particle_Id{added, fill, b, a}
	for id in ids {
		e.particles.flags[id] += {.Visible}
		e.particles.current_coord[id] = {1, 1}
	}
	// Setter order must not decide equal-layer collisions. Spaces between
	// input glyphs, fills and added glyphs all retain creation-order priority.
	engine.compose_frame(&e)
	testing.expect_value(t, draw_at(&e, 0), i32(added))
	engine.compose_frame(&e)
	testing.expect_value(t, draw_at(&e, 0), i32(added))
	engine.set_particle(&e, added, engine.Visible(false))
	engine.compose_frame(&e)
	testing.expect_value(t, draw_at(&e, 0), i32(fill))
	engine.set_particle(&e, fill, engine.Visible(false))
	engine.compose_frame(&e)
	testing.expect_value(t, draw_at(&e, 0), i32(b))
	engine.set_particle(&e, a, engine.Layer(1))
	engine.compose_frame(&e)
	testing.expect_value(t, draw_at(&e, 0), i32(a))
	engine.compose_frame(&e)
	testing.expect_value(t, draw_at(&e, 0), i32(a))
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
	// Decoded glyphs remain valid when parser scratch is reclaimed.
	free_all(context.temp_allocator)
	testing.expect_value(t, waves.wave_symbols[1], '-')
}

@(test)
symbol_flags_decode_single_unicode_scalars :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	for input in ([]string{"", "AB", "e\u0301", "\xff", "\xed\xa0\x80"}) {
		symbol: rune
		index := 0
		testing.expect(
			t,
			!effects.parse_symbol_flag(&symbol, []string{input}, &index, input, true),
		)
		symbols: [dynamic]rune
		testing.expect(
			t,
			!effects.parse_symbols_flag(&symbols, []string{input}, &index, input, true),
		)
	}
	input := []string{"A", "é", "░", "𐍈", "�"}
	expected := []rune{'A', 'é', '░', '𐍈', '�'}
	for value, i in input {
		symbol: rune
		index := 0
		testing.expect(t, effects.parse_symbol_flag(&symbol, []string{value}, &index, value, true))
		testing.expect_value(t, symbol, expected[i])
	}
	symbols: [dynamic]rune
	index := 0
	testing.expect(
		t,
		effects.parse_symbols_flag(
			&symbols,
			[]string{"A é ░ 𐍈 �"},
			&index,
			"A é ░ 𐍈 �",
			true,
		),
	)
	testing.expect_value(t, len(symbols), len(expected))
	for symbol, i in symbols do testing.expect_value(t, symbol, expected[i])
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
		for id in run.engine_state.particle_sets.input do testing.expect(t, (.Visible in run.engine_state.particles.flags[id]))
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
	e, err := engine.engine_make("Hello, World!\nThis is otfx.\nOdin vs Rust", cfg)
	testing.expect(t, err == .None)
	state := effects.Rings_State {
		config = effects.rings_config_default(),
	}
	effects.rings_build(&state, &e)
	before := track.total_allocation_count
	for i in 0 ..< 3 do effects.rings_begin_disperse(&state, &e, i == 0)
	testing.expect_value(t, track.total_allocation_count, before)
}
