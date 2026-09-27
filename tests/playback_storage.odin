package regression

import "../src/effects"
import "../src/engine"
import "core:fmt"
import "core:mem"
import "core:testing"

@(test)
particle_batch_creates_reserved_population_without_allocating :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, mem.dynamic_arena_allocator(&arena))
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 1, 1
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("A", cfg)
	testing.expect_value(t, err, engine.Input_Error.None)
	first := len(e.particles)
	shared := engine.prepare_appearance(&e, engine.Appearance{})
	batch := engine.particle_batch(&e, 130)
	allocations := track.total_allocation_count
	for i in 0 ..< 130 {
		id := engine.add_particle(&batch, 'B', shared, engine.coord(1, 1))
		testing.expect_value(t, int(id), first + i)
		engine.set_particle(&e, id, engine.Visible(true))
	}
	testing.expect_value(t, track.total_allocation_count, allocations)
	// The last added particle wins at equal layer priority.
	engine.set_symbol(&e, engine.Particle_Id(len(e.particles) - 1), 'Z')
	engine.frame_build(&e)
	testing.expect_value(t, e.particles.symbol[len(e.particles) - 1], 'Z')
	// Ordinary creation remains valid after the batch is consumed.
	id := engine.add_particle(
		&e,
		'C',
		engine.prepare_appearance(&e, engine.Appearance{}),
		engine.coord(1, 1),
	)
	testing.expect_value(t, int(id), first + 130)
	engine.set_particle(&e, id, engine.Visible(true))
	engine.frame_build(&e)
	testing.expect_value(t, e.particles.symbol[id], 'C')
}

@(test)
rebuilt_output_storage_does_not_grow :: proc(t: ^testing.T) {
	base_allocator := context.allocator
	// Rebuilding for growth and then shrink must derive a fresh reservation.
	for no_color in ([]bool{false, true}) {
		previous_capacity := 0
		for dimensions, index in ([]engine.Coord{{1, 1}, {40, 12}, {200, 50}, {7, 3}}) {
			arena: mem.Dynamic_Arena
			mem.dynamic_arena_init(&arena)
			defer mem.dynamic_arena_destroy(&arena)
			track: mem.Tracking_Allocator
			mem.tracking_allocator_init(&track, mem.dynamic_arena_allocator(&arena))
			defer mem.tracking_allocator_destroy(&track)
			context.allocator = mem.tracking_allocator(&track)
			defer context.allocator = base_allocator
			cfg := engine.config_default()
			cfg.canvas_width, cfg.canvas_height = dimensions.column, dimensions.row
			cfg.ignore_terminal_dimensions, cfg.no_color = true, no_color
			e, err := engine.engine_make("A", cfg)
			testing.expect(t, err == .None)
			capacity := len(e.slots) + len(e.output)
			if index > 0 do testing.expect_value(t, capacity > previous_capacity, index < 3)
			previous_capacity = capacity
			allocations := track.total_allocation_count
			// Full styled output, then sparse glyphs, erased cells, and skipped
			// rows exercise both encoded cell size and relative cursor movement.
			for pass in 0 ..< 5 {
				for id in 0 ..< len(e.particles) {
					engine.set_particle(
						&e,
						engine.Particle_Id(id),
						engine.Visible(
							pass == 0 ||
							(pass == 1 && id % 2 == 0) ||
							(pass == 3 && e.particles.current_coord[id].row % 3 == 0) ||
							(pass == 4 && id == len(e.particles) - 1),
						),
					)
					engine.set_symbol(&e, engine.Particle_Id(id), '𐍈')
					engine.set_appearance(
						&e,
						engine.Particle_Id(id),
						engine.Appearance {
							bold = true,
							colors = {
								fg = engine.Color{255, 254, u8(pass)},
								bg = engine.Color{253, 252, 251},
							},
						},
					)
				}
				engine.frame_build(&e)
				testing.expect_value(t, track.total_allocation_count, allocations)
				testing.expect_value(t, len(e.slots) + len(e.output), capacity)
			}
		}
	}
}

@(test)
bounded_playback_reuses_build_storage :: proc(t: ^testing.T) {
	base_allocator := context.allocator
	for kind in effects.Effect_Kind {
		// Recursive strike generation and overlapping spark pools remain dynamic.
		if kind == .Thunderstorm do continue
		arena: mem.Dynamic_Arena
		mem.dynamic_arena_init(&arena)
		defer mem.dynamic_arena_destroy(&arena)
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, mem.dynamic_arena_allocator(&arena))
		defer mem.tracking_allocator_destroy(&track)
		context.allocator = mem.tracking_allocator(&track)
		defer context.allocator = base_allocator
		cfg := engine.config_default()
		cfg.canvas_width, cfg.canvas_height, cfg.frame_rate = 40, 12, 0
		cfg.ignore_terminal_dimensions, cfg.virtual_clock = true, true
		engine.random_seed(42)
		e, err := engine.engine_make("Playback storage\nA B C D\nFinal row", cfg)
		testing.expect(t, err == .None)
		fx, ok := effects.make_effect(kind, nil)
		testing.expect(t, ok)
		effects.build_effect(&fx, &e)
		free_all(context.temp_allocator)
		allocations := track.total_allocation_count
		frames := 0
		for frames < 50_000 {
			alive := effects.next_frame(&fx, &e)
			if !alive do break
			engine.frame_build(&e)
			free_all(context.temp_allocator)
			frames += 1
		}
		testing.expect(t, frames < 50_000)
		testing.expect_value(t, track.total_allocation_count, allocations, value_expr = fmt.tprintf("%v playback allocations", kind))
	}
}
