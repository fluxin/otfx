package regression

import "../src/engine"
import "core:math/ease"
import "core:mem"
import "core:testing"

@(test)
sequence_keypoints_clip_and_load_through_one_queue :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	frames: #soa[8]engine.Sequence_Frame
	factors: [8]f64
	for i in 0 ..< len(frames) do frames[i] = {{-1, -1}, {}}
	actions := [?]engine.Sequence_Action {
		engine.Position_Action{{2, 1}},
		engine.Colors_Action{{fg = engine.Color{10, 20, 30}}},
	}
	override := [?]engine.Sequence_Action{engine.Colors_Action{{bg = engine.Color{1, 2, 3}}}}
	keypoints := [?]engine.Sequence_Keypoint{{2, 6, actions[:]}, {4, 7, override[:]}}
	engine.sequence_batch(frames[:], factors[:], 1, keypoints[:])
	testing.expect_value(t, frames.coord[0], engine.Coord{-1, -1})
	testing.expect_value(t, frames.coord[1], engine.Coord{2, 1})
	testing.expect_value(t, frames.coord[5], engine.Coord{-1, -1})
	testing.expect_value(t, frames.colors[3], engine.Color_Pair{bg = engine.Color{1, 2, 3}})
	testing.expect_value(t, frames.colors[6], engine.Color_Pair{})
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 2, 1
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("A", cfg)
	testing.expect_value(t, err, engine.Input_Error.None)
	ids := [?]engine.Particle_Id{e.particle_sets.input[0]}
	engine.set_visible(&e, ids[0], true)
	engine.frame_build(&e)
	engine.set_particle(&e, ids[:], frames[1:2])
	engine.set_particle(&e, ids[0], frames[1])
	testing.expect_value(t, len(e.updates), 1)
	testing.expect_value(t, e.particles.current_coord[ids[0]], engine.Coord{2, 1})
	engine.frame_build(&e)
	testing.expect_value(t, e.cells[1].top, ids[0])
	testing.expect_value(t, engine.get_appearance(&e, ids[0]).colors, frames.colors[1])
	engine.set_particle(&e, ids[:], frames[1:2])
	testing.expect_value(t, len(e.updates), 0)
}

@(test)
sequence_actions_preserve_scalar_samples :: proc(t: ^testing.T) {
	frames: #soa[17]engine.Sequence_Frame
	factors: [17]f64
	palette := [?]engine.Color{{10, 20, 30}, {80, 90, 100}, {240, 250, 255}}
	from, to := engine.Coord{-11, 9}, engine.Coord{37, -20}
	for fn in ([]ease.Ease{.Sine_Out, .Sine_In_Out, .Quadratic_In_Out}) {
		actions := [?]engine.Sequence_Action {
			engine.Ease_Action{fn},
			engine.Move_Action{from, to},
			engine.Palette_Action{palette[:], {bg = engine.Color{4, 5, 6}}, true},
		}
		keypoints := [?]engine.Sequence_Keypoint{{0, 23, actions[:]}}
		engine.sequence_batch(frames[:], factors[:], 2, keypoints[:])
		for i in 0 ..< len(frames) {
			factor := ease.ease(fn, f64(i + 3) / 23)
			testing.expect_value(t, frames.coord[i], engine.tween(from, to, factor))
			entry := clamp(engine.round_to_int(2 * factor), 0, 2)
			testing.expect_value(
				t,
				frames.colors[i],
				engine.Color_Pair{fg = palette[entry], bg = engine.Color{4, 5, 6}},
			)
		}
	}
}

@(test)
sequence_gradient_chunks_preserve_holds_and_absent_channels :: proc(t: ^testing.T) {
	frames: #soa[36]engine.Sequence_Frame
	factors: [16]f64
	from := engine.Color{220, 120, 30}
	to := engine.Color{20, 70, 200}
	for start := 0; start < 33; start += 16 {
		end := min(start + 16, 33)
		actions := [?]engine.Sequence_Action {
			engine.Position_Action{{8, 12}},
			engine.Gradient_Action{{fg = from, bg = from}, {bg = to}, 3, 10},
		}
		keypoints := [?]engine.Sequence_Keypoint{{0, 33, actions[:]}}
		engine.sequence_batch(frames[start:end], factors[:], start, keypoints[:])
	}
	clear_actions := [?]engine.Sequence_Action{engine.Colors_Action{{}}}
	keypoints := [?]engine.Sequence_Keypoint{{33, 36, clear_actions[:]}}
	engine.sequence_batch(frames[33:36], factors[:], 33, keypoints[:])
	for i in 0 ..< 33 {
		testing.expect_value(t, frames.coord[i], engine.Coord{8, 12})
		testing.expect_value(
			t,
			frames.colors[i],
			engine.Color_Pair{bg = engine.tween(from, to, 10, i / 3)},
		)
	}
	for i in 33 ..< 36 do testing.expect_value(t, frames.colors[i], engine.Color_Pair{})
}
