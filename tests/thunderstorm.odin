package regression

import effects "../src/effects"
import engine "../src/engine"
import "core:mem"
import "core:testing"

@(test)
thunderstorm_flashes_unstruck_text_then_glows_only_struck_cells :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	for handling in ([]engine.Existing_Color_Handling{.Ignore, .Dynamic, .Always}) {
		cfg := engine.config_default()
		cfg.canvas_width, cfg.canvas_height = 3, 1
		cfg.ignore_terminal_dimensions = true
		cfg.existing_color_handling = handling
		e, err := engine.engine_make("\x1b[38;2;80;100;120;48;2;20;30;40mABC\x1b[0m", cfg)
		testing.expect_value(t, err, engine.Input_Error.None)
		s := effects.Thunderstorm_State {
			config = effects.thunderstorm_config_default(),
		}
		effects.thunderstorm_build(&s, &e)
		for id, i in s.characters {
			engine.set_foreground(&e, id, s.storm_colors[i])
			engine.set_background(&e, id, s.storm_bg[i])
		}
		// A single bolt covers B. A has an earlier glow that this flash replaces.
		a, b, c := s.characters[0], s.characters[1], s.characters[2]
		bolt := s.strike_ids[0]
		engine.set_placement(&e, bolt, e.particles.initial_coord[b], true, 2)
		append(&s.strike_pending, bolt)
		s.strike_pending_head, s.strike_flash_age, s.strike_live = 1, 0, true
		s.glow_starts[0] = 0
		append(&s.glow_active, 0)
		for age in 0 ..= 54 {
			s.tick = age
			effects.thunderstorm_reveal_strike(&s, &e)
			effects.thunderstorm_update_text(&s, &e)
			engine.frame_build(&e)
			if age < 54 {
				testing.expect_value(t, len(s.glow_active), 0)
				for id in ([]engine.Particle_Id{a, c}) {
					testing.expect_value(t, e.cells[e.particles[id].cell].top, id)
				}
			}
			if age == 18 || age == 36 {
				for id, i in s.characters {
					want := s.flash_colors[i] if age == 18 else s.storm_colors[i]
					testing.expect_value(t, engine.get_appearance(&e, id).colors.fg.?, want)
					testing.expect_value(t, engine.get_appearance(&e, id).colors.bg, s.storm_bg[i])
					if handling == .Always {
						testing.expect_value(
							t,
							engine.get_render_appearance(&e, id).colors,
							engine.get_initial_appearance(&e, id).colors,
						)
					}
				}
			}
		}
		testing.expect(t, !s.strike_live)
		testing.expect_value(t, len(s.glow_active), 1)
		testing.expect_value(t, s.glow_active[0], 1)
		testing.expect_value(t, e.cells[e.particles[b].cell].top, b)
		testing.expect_value(
			t,
			engine.get_appearance(&e, b).colors.fg.?,
			s.config.glowing_text_color,
		)
		for index in ([]int{0, 2}) {
			testing.expect_value(
				t,
				engine.get_appearance(&e, s.characters[index]).colors.fg.?,
				s.storm_colors[index],
			)
		}
	}
}

@(test)
thunderstorm_nested_branch_replay :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	work: effects.Thunderstorm_Strike_Work
	// Three-row trunk, a child at its top, and a grandchild on the child's
	// second row. Parent continuations must wait for the whole child subtree.
	append(
		&work.segments,
		effects.Thunderstorm_Strike_Segment{row = 3, child = 4},
		effects.Thunderstorm_Strike_Segment{row = 2},
		effects.Thunderstorm_Strike_Segment{row = 1},
		effects.Thunderstorm_Strike_Segment{row = 3},
		effects.Thunderstorm_Strike_Segment{row = 2, child = 7},
		effects.Thunderstorm_Strike_Segment{row = 1},
		effects.Thunderstorm_Strike_Segment{row = 2},
		effects.Thunderstorm_Strike_Segment{row = 1},
	)
	effects.thunderstorm_strike_order(&work, engine.canvas_make(3, 10))
	expected := []int{0, 3, 4, 6, 7, 5, 1, 2}
	testing.expect_value(t, len(work.order), len(expected))
	for index, i in expected do testing.expect_value(t, work.order[i], index)
}

@(test)
thunderstorm_recursive_geometry :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	recursive, exceeds_old_capacity := false, false
	for height in ([]int{1, 2, 24, 50, 100}) {
		for seed in 1 ..= 64 {
			engine.random_seed(u64(seed))
			work: effects.Thunderstorm_Strike_Work
			canvas := engine.canvas_make(height, 200)
			effects.thunderstorm_strike_generate(&work, canvas, 100)
			n := len(work.segments)
			exceeds_old_capacity ||= n > height * (height + 3) / 2
			testing.expect_value(t, len(work.order), n)
			seen := make([]bool, n)
			for index in work.order {
				testing.expect(t, index >= 0 && index < n)
				testing.expect(t, !seen[index])
				seen[index] = true
			}
			for segment, i in work.segments {
				testing.expect(t, segment.row >= 1 && segment.row <= height && segment.symbol <= 2)
				if segment.row > 1 {
					next := work.segments[i + 1]
					testing.expect_value(t, next.row, segment.row - 1)
					testing.expect_value(
						t,
						next.column,
						segment.column + int(segment.symbol == 0) - int(segment.symbol == 1),
					)
				}
				if segment.child != 0 {
					child := segment.child - 1
					first := work.segments[child]
					testing.expect_value(t, first.row, segment.row)
					testing.expect(t, first.symbol <= 1)
					testing.expect_value(
						t,
						first.column,
						segment.column + 1 - 2 * int(first.symbol),
					)
					testing.expect_value(t, first.child, 0)
					for j in child + 1 ..< child + segment.row do recursive ||= work.segments[j].child != 0
				}
			}
			free_all(context.temp_allocator)
		}
	}
	testing.expect(t, recursive, "side branches must be able to branch after their first row")
	testing.expect(
		t,
		exceeds_old_capacity,
		"recursive geometry must grow past the old quadratic pool",
	)
}

@(test)
thunderstorm_replay_survives_scratch_reset :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, mem.dynamic_arena_allocator(&arena))
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 80, 50
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("hello", cfg)
	testing.expect(t, err == .None)
	s := effects.Thunderstorm_State {
		config = effects.thunderstorm_config_default(),
	}
	effects.thunderstorm_build(&s, &e)
	engine.random_seed(42)
	effects.thunderstorm_begin_strike(&s, &e)
	count := len(s.strike_pending)
	expected := make([]engine.Coord, count)
	for id, i in s.strike_pending do expected[i] = e.particles.current_coord[id]
	free_all(context.temp_allocator)
	before := track.total_allocation_count
	for s.strike_pending_head + 3 < count {
		effects.thunderstorm_reveal_strike(&s, &e)
		for id, i in s.strike_pending {
			testing.expect_value(t, e.particles.current_coord[id], expected[i])
			testing.expect_value(t, (.Visible in e.particles.flags[id]), i < s.strike_pending_head)
		}
	}
	testing.expect_value(t, track.total_allocation_count, before)
	// The same seed must rebuild the same geometry and reuse the pool.
	for id in s.strike_pending do e.particles.flags[id] -= {.Visible}
	allocated_chars := len(e.particles)
	engine.random_seed(42)
	effects.thunderstorm_begin_strike(&s, &e)
	testing.expect_value(t, track.total_allocation_count, before)
	testing.expect_value(t, len(e.particles), allocated_chars)
	testing.expect_value(t, len(s.strike_pending), count)
	for id, i in s.strike_pending do testing.expect_value(t, e.particles.current_coord[id], expected[i])
	free_all(context.temp_allocator)
	for s.strike_live {
		effects.thunderstorm_reveal_strike(&s, &e)
	}
	testing.expect_value(t, s.strike_pending_head, 0)
	testing.expect_value(t, len(s.strike_pending), 0)
	for id in s.strike_ids do testing.expect(t, (.Visible not_in e.particles.flags[id]))
}
