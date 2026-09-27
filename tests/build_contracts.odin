package regression

import "../src/effects"
import "../src/engine"
import "core:math/rand"
import "core:mem"
import "core:testing"

@(test)
unstable_settled_motion_keeps_dynamic_color_finish :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.ignore_terminal_dimensions = true
	cfg.existing_color_handling = .Dynamic
	rand.reset_u64(42)
	e, err := engine.engine_make("\x1b[31;44mA\x1b[0m B", cfg)
	testing.expect(t, err == .None)
	s := effects.Unstable_State {
		config = effects.unstable_config_default(),
	}
	s.config.explosion_speed, s.config.reassembly_speed = 100000, 100000
	effects.unstable_build(&s, &e)
	free_all(context.temp_allocator)
	frames, restored := 0, false
	for effects.unstable_next(&s, &e) {
		if s.phase == .Reassembly {
			for id in s.characters {
				testing.expect_value(
					t,
					e.particles[id].current_coord,
					e.particles[id].initial_coord,
				)
				if engine.get_initial_appearance(&e, id).colors.fg == nil {
					fg := engine.get_appearance(&e, id).colors.fg
					if s.phase_tick == 39 do testing.expect(t, fg != nil)
					if s.phase_tick == 40 {
						testing.expect(t, fg == nil)
						restored = true
					}
				}
			}
		}
		engine.frame_build(&e)
		free_all(context.temp_allocator)
		frames += 1
		if frames > 300 {testing.expect(t, false, "unstable did not finish"); break}
	}
	testing.expect(t, restored)
	testing.expect_value(t, frames, 150 + 1 + 30 + 42)
	for id in s.characters {
		testing.expect_value(
			t,
			engine.get_appearance(&e, id).colors,
			engine.get_initial_appearance(&e, id).colors,
		)
	}
}

@(test)
spotlights_stationary_frames_still_advance_and_restore_colors :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.ignore_terminal_dimensions = true
	cfg.existing_color_handling = .Dynamic
	e, err := engine.engine_make("X", cfg)
	testing.expect(t, err == .None)
	s := effects.Spotlights_State {
		config = effects.spotlights_config_default(),
	}
	s.config.spotlight_count, s.config.search_duration = 1, 2
	effects.spotlights_build(&s, &e)
	free_all(context.temp_allocator)
	s.spot_positions[0], s.spot_origins[0] = e.canvas.center, e.canvas.center
	s.spot_controls[0], s.spot_targets[0] = e.canvas.center, e.canvas.center
	s.spot_steps[0], s.spot_ticks[0] = 100, 0
	id := s.characters[0]
	for frame in 0 ..< 4 {
		testing.expect(t, step_frame(effects.spotlights_next, &s, &e))
		if frame < 3 do testing.expect(t, engine.get_appearance(&e, id).colors.fg != nil)
	}
	testing.expect_value(t, s.phase, effects.Spotlights_Phase.Expand)
	testing.expect(t, engine.get_appearance(&e, id).colors.fg == nil)
}

@(test)
expand_publishes_arrival_before_retiring :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	for mode in ([]engine.Existing_Color_Handling{.Ignore, .Always, .Dynamic}) {
		cfg := engine.config_default()
		cfg.ignore_terminal_dimensions = true
		cfg.existing_color_handling = mode
		e, err := engine.engine_make("\x1b[31;44mA\x1b[0m B C\nD E F", cfg)
		testing.expect(t, err == .None)
		s := effects.Expand_State {
			config = effects.expand_config_default(),
		}
		effects.expand_build(&s, &e)
		retired := make([]bool, len(e.particles))
		frames := 0
		for effects.expand_next(&s, &e) {
			for update in e.updates do testing.expect(t, !retired[update.id], "completed particles must leave the update work set")
			for id, i in s.characters {
				if s.tick < s.max_steps[s.motion_slots[i]] do continue
				testing.expect_value(
					t,
					e.particles.current_coord[id],
					e.particles.initial_coord[id],
				)
				testing.expect_value(t, e.particles.layer[id], 0)
				if mode == .Dynamic {
					testing.expect_value(
						t,
						engine.get_appearance(&e, id).colors,
						engine.get_initial_appearance(&e, id).colors,
					)
				} else {
					testing.expect(t, engine.get_appearance(&e, id).colors.bg == nil)
				}
				retired[id] = true
			}
			engine.frame_build(&e)
			free_all(context.temp_allocator)
			frames += 1
			if frames > 1000 {testing.expect(t, false, "expand did not finish"); break}
		}
		testing.expect_value(t, frames, s.step_limit)
		testing.expect_value(t, len(s.active_indexes), 0)
	}
}

@(test)
fireworks_retires_after_motion_and_color_finish :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	for mode in ([]engine.Existing_Color_Handling{.Ignore, .Always, .Dynamic}) {
		cfg := engine.config_default()
		cfg.ignore_terminal_dimensions = true
		cfg.existing_color_handling = mode
		rand.reset_u64(42)
		e, err := engine.engine_make("\x1b[31;44mABCDEFGH\x1b[0m\nIJKLMNOP\nQRSTUVWX", cfg)
		testing.expect(t, err == .None)
		s := effects.Fireworks_State {
			config = effects.fireworks_config_default(),
		}
		s.config.launch_delay = 3
		effects.fireworks_build(&s, &e)
		retired := make([]bool, len(e.particles))
		frames := 0
		for effects.fireworks_next(&s, &e) {
			for update in e.updates do testing.expect(t, !retired[update.id], "completed particles must not be revisited by later shells")
			for id, i in s.characters {
				start := s.shell_start_ticks[s.shell_index[i]]
				if start < 0 || s.tick - start < s.finish_ages[i] do continue
				testing.expect_value(
					t,
					e.particles.current_coord[id],
					e.particles.initial_coord[id],
				)
				if mode == .Dynamic {
					testing.expect_value(
						t,
						engine.get_appearance(&e, id).colors,
						engine.get_initial_appearance(&e, id).colors,
					)
				} else {
					testing.expect(t, engine.get_appearance(&e, id).colors.bg == nil)
				}
				retired[id] = true
			}
			engine.frame_build(&e)
			free_all(context.temp_allocator)
			frames += 1
			if frames > 2000 {testing.expect(t, false, "fireworks did not finish"); break}
		}
		testing.expect_value(t, s.next_shell, -1)
		testing.expect_value(t, len(s.active_indexes), 0)
		for id in s.characters do testing.expect(t, retired[id])
	}
}
