package regression

import "../src/effects"
import "../src/engine"
import "core:math/ease"
import "core:math/rand"
import "core:mem"
import "core:strings"
import "core:testing"

@(test)
middleout_finishes_color_and_motion :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	for mode in ([]engine.Existing_Color_Handling{.Ignore, .Dynamic}) {
		cfg := engine.config_default()
		cfg.ignore_terminal_dimensions = true
		cfg.existing_color_handling = mode
		e, err := engine.engine_make("X", cfg, context.allocator)
		testing.expect(t, err == .None)
		s := effects.Middleout_State {
			config = effects.middleout_config_default(),
		}
		effects.middleout_build(&s, &e)
		free_all(context.temp_allocator)
		frames := 0
		for {
			_, alive := effects.middleout_next(&s, &e)
			if !alive do break
			frames += 1
			if frames > 1000 {testing.expect(t, false, "failed to complete"); break}
		}
		id := s.characters[0]
		testing.expect_value(t, e.chars.current_coord[id], e.chars.input_coord[id])
		if mode == .Ignore {
			testing.expect_value(t, e.chars.visual[id].fg, Maybe(engine.Color)(s.final_colors[0]))
			testing.expect_value(t, s.full_limit, 66)
		} else {
			testing.expect(t, e.chars.visual[id].fg == nil)
			testing.expect_value(t, s.full_limit, 6)
		}
	}
}

@(test)
waves_stretch_each_wave :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	for count in ([]int{2, 6}) {
		cfg := engine.config_default()
		cfg.ignore_terminal_dimensions = true
		e, _ := engine.engine_make("X", cfg, context.allocator)
		s := effects.Waves_State {
			config = effects.waves_config_default(),
		}
		s.config.wave_count = 2
		clear(&s.config.wave_symbols)
		symbols := []string{"a", "b", "c", "d", "e", "f"}
		append(&s.config.wave_symbols, ..symbols[:count])
		clear(&s.config.wave_gradient_stops)
		append(&s.config.wave_gradient_stops, engine.Color{0, 0, 0}, engine.Color{255, 255, 255})
		clear(&s.config.wave_gradient_steps)
		append(&s.config.wave_gradient_steps, 3)
		effects.waves_build(&s, &e)
		free_all(context.temp_allocator)
		expected := count == 2 ? []string{"a", "a", "b", "b"} : symbols
		testing.expect_value(t, len(s.wave_symbols), 2 * len(expected))
		for symbol, i in s.wave_symbols do testing.expect_value(t, symbol, expected[i % len(expected)])
		testing.expect_value(t, s.wave_colors[len(expected) - 1], engine.Color{255, 255, 255})
	}
}

@(test)
synthgrid_launches_one_block_per_tick :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.ignore_terminal_dimensions = true
	cfg.canvas_width, cfg.canvas_height = 84, 13
	e, _ := engine.engine_make("X", cfg, context.allocator)
	s := effects.Synthgrid_State {
		config = effects.synthgrid_config_default(),
	}
	s.config.max_active_blocks = 0.13
	effects.synthgrid_build(&s, &e)
	free_all(context.temp_allocator)
	threshold := f64(len(s.groups.spans)) * s.config.max_active_blocks
	testing.expect(t, f64(s.active_limit) >= threshold && f64(s.active_limit - 1) < threshold)
	s.phase = .Text
	for tick in 0 ..< s.active_limit + 1 {
		before := s.next_group
		effects.synthgrid_next(&s, &e)
		testing.expect_value(t, s.next_group - before, tick < s.active_limit ? 1 : 0)
	}
}

@(test)
spotlights_render_before_radius_increment :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.ignore_terminal_dimensions = true
	cfg.canvas_width, cfg.canvas_height = 9, 3
	e, _ := engine.engine_make("X", cfg, context.allocator)
	s := effects.Spotlights_State {
		config = effects.spotlights_config_default(),
	}
	effects.spotlights_build(&s, &e)
	free_all(context.temp_allocator)
	s.phase = .Expand
	s.illuminate_range, s.expand_limit = 2, 2
	id := s.characters[0]
	p := e.chars.input_coord[id]
	for &spot in s.spot_positions do spot = engine.coord(p.column + 3, p.row)
	_, alive := effects.spotlights_next(&s, &e)
	testing.expect(t, alive)
	testing.expect_value(t, e.chars.visual[id].fg, Maybe(engine.Color)(s.dark_colors[0]))
	_, alive = effects.spotlights_next(&s, &e)
	testing.expect(t, !alive)
}

@(test)
bubbles_pop_motion_and_color_are_independent :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.ignore_terminal_dimensions = true
	cfg.canvas_width, cfg.canvas_height = 60, 30
	e, _ := engine.engine_make("ABCDE", cfg, context.allocator)
	s := effects.Bubbles_State {
		config = effects.bubbles_config_default(),
	}
	s.config.rainbow = true
	s.config.bubble_speed = 0.01
	effects.bubbles_build(&s, &e)
	free_all(context.temp_allocator)
	id := s.characters[0]
	s.delay = 0
	for tick in 0 ..< 5 {
		effects.bubbles_next(&s, &e)
		testing.expect_value(
			t,
			e.chars.visual[id].fg,
			Maybe(engine.Color)(s.rainbow_palette[s.color_offsets[id] + tick / 4]),
		)
	}
	// Force a pop far from its destination. Scene restoration must happen
	// while the expansion path is still active, not after a held teleport.
	s.bubble_states[0] = .Pop
	s.pop_starts[0] = s.tick
	for member in engine.group_members(s.bubbles, 0) {
		s.pop_origins[member] = engine.coord(20, 20)
		s.pop_targets[member] = engine.coord(26, 23)
		s.expand_steps[member] = 40
		s.pop_steps[member] = 100
	}
	for tick in 0 ..< 19 {
		effects.bubbles_next(&s, &e)
		if tick == 0 {
			testing.expect(t, e.chars.current_coord[id] != s.pop_targets[id])
			testing.expect_value(t, e.chars.visual[id].symbol, "*")
		}
	}
	testing.expect_value(t, e.chars.visual[id].symbol, e.chars.input_symbol[id])
	testing.expect(t, e.chars.current_coord[id] != e.chars.input_coord[id])
	testing.expect_value(t, s.bubble_states[0], effects.Bubbles_Bubble_State.Pop)
}

@(test)
blackhole_pulses_before_explosion :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.ignore_terminal_dimensions = true
	e, _ := engine.engine_make("BLACK HOLE", cfg, context.allocator)
	s := effects.Blackhole_State {
		config = effects.blackhole_config_default(),
	}
	effects.blackhole_build(&s, &e)
	free_all(context.temp_allocator)
	frames, pulses := 0, 0
	symbols := []string{"◦", "◎", "◉", "●", "◉", "◎", "◦"}
	id := s.characters[s.ring_sources[0]]
	for {
		_, alive := effects.blackhole_next(&s, &e)
		if !alive do break
		frames += 1
		if frames > 5000 {testing.expect(t, false, "failed to complete"); break}
		if s.phase == .Collapsing && e.chars.layer[id] == 3 && pulses < 63 {
			testing.expect_value(t, e.chars.visual[id].symbol, symbols[(pulses / 3) % 7])
			testing.expect_value(t, e.chars.current_coord[id], e.canvas.center)
			pulses += 1
		}
	}
	testing.expect_value(t, pulses, 63)
	for char, i in s.characters {
		testing.expect_value(t, e.chars.current_coord[char], e.chars.input_coord[char])
		testing.expect_value(t, e.chars.visual[char].fg, Maybe(engine.Color)(s.final_colors[i]))
	}
}

@(test)
bubbles_mixed_styles_finish_the_longest_scene :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.ignore_terminal_dimensions = true
	cfg.existing_color_handling = .Dynamic
	e, _ := engine.engine_make("ABCD\x1b[31mE\x1b[0m", cfg, context.allocator)
	s := effects.Bubbles_State {
		config = effects.bubbles_config_default(),
	}
	effects.bubbles_build(&s, &e)
	free_all(context.temp_allocator)
	s.next_bubble = len(s.bubbles.spans)
	s.bubble_states[0] = .Pop
	for id in s.characters {
		s.pop_origins[id], s.pop_targets[id] = e.chars.input_coord[id], e.chars.input_coord[id]
		s.expand_steps[id], s.pop_steps[id] = 1, 1
	}
	for tick in 0 ..< 72 {
		_, alive := effects.bubbles_next(&s, &e)
		testing.expect(t, alive)
		if tick < 71 do testing.expect_value(t, s.bubble_states[0], effects.Bubbles_Bubble_State.Pop)
	}
	_, alive := effects.bubbles_next(&s, &e)
	testing.expect(t, !alive)
	for id in s.characters do testing.expect_value(t, e.chars.visual[id].fg, e.chars.input_style[id].fg)
}

@(test)
swarm_keeps_tail_and_interrupted_motion :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.ignore_terminal_dimensions = true
	cfg.canvas_width, cfg.canvas_height = 40, 12
	e, _ := engine.engine_make(strings.repeat("X", 23), cfg, context.allocator)
	s := effects.Swarm_State {
		config = effects.swarm_config_default(),
	}
	s.config.swarm_size = 0.3 // groups of seven plus a two-character tail
	s.config.swarm_area_count_range = {5, 5}
	rand.reset_u64(42)
	effects.swarm_build(&s, &e)
	free_all(context.temp_allocator)
	count := 0
	for span in s.swarms.spans do count += span.len
	testing.expect_value(t, count, 23)
	for stages in s.group_stage_counts do testing.expect_value(t, stages, 16)
	interrupted := false
	for i in 0 ..< len(s.characters) {
		for stage in 0 ..< s.group_stage_counts[s.group_by_index[i]] {
			row := effects.swarm_lane_index(&s, i, stage)
			start, end := s.lane_starts[row], s.lane_ends[row]
			if end <= start || end - start >= s.lane_steps[row] do continue
			interrupted = true
			p := effects.swarm_lane_position(&s, i, stage, end)
			next_row := effects.swarm_lane_index(&s, i, s.lane_next[row])
			testing.expect_value(t, p, s.lane_origins[next_row])
		}
	}
	testing.expect(t, interrupted)
	testing.expect_value(t, effects.swarm_stage_easing(0, 16), ease.Ease.Sine_Out)
	for group in 0 ..< len(s.swarms.spans) {
		palette := s.flash_colors[group * 26:][:26]
		testing.expect_value(t, palette[0], palette[25])
		for entry in 7 ..= 18 do testing.expect_value(t, palette[entry], s.config.flash_color)
	}
	frames := 0
	saw_inner_motion := false
	for {
		_, alive := effects.swarm_next(&s, &e)
		if !alive do break
		frames += 1
		for i in s.active_indexes {
			stage := s.character_stages[i]
			if stage % 3 != 0 {
				saw_inner_motion = true
				testing.expect_value(
					t,
					e.chars.visual[s.characters[i]].fg,
					Maybe(engine.Color)(s.flash_colors[s.group_by_index[i] * 26]),
				)
			}
		}
		if frames > 20000 {testing.expect(t, false, "failed to complete"); break}
	}
	testing.expect(t, saw_inner_motion)
	for id, i in s.characters {
		testing.expect(t, e.chars.is_visible[id])
		testing.expect_value(t, e.chars.current_coord[id], e.chars.input_coord[id])
		testing.expect_value(t, e.chars.visual[id].fg, Maybe(engine.Color)(s.final_colors[i]))
	}
}
