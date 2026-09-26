package regression

import "../src/engine"
import "core:mem"
import "core:strings"
import "core:testing"

@(test)
row_bytes_preserve_variable_length_cells :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	for no_color in ([]bool{false, true}) {
		cfg := engine.config_default()
		cfg.canvas_width, cfg.canvas_height = 65, 2
		cfg.ignore_terminal_dimensions, cfg.no_color = true, no_color
		e, err := engine.engine_make("A", cfg, context.allocator)
		testing.expect_value(t, err, engine.Input_Error.None)
		for id in 0 ..< len(e.particles) do engine.set_particle(&e, engine.Particle_Id(id), visible = true)
		engine.frame_build(&e)
		glyphs := []string{"A", "é", "░", "𐍈", "long symbol", ""}
		builder := strings.builder_make()
		// Sparse edits shift both ends of a row; dense edits exercise rebuilding.
		// Repeated changes before emission must use the final encoded length.
		for tick in 0 ..< 48 {
			count := 65 if tick % 4 == 0 else 3
			for i in 0 ..< count {
				id := engine.Particle_Id((i * 17 + tick * 13) % len(e.particles))
				engine.set_symbol(&e, id, glyphs[(i + tick) % len(glyphs)])
				engine.set_foreground(&e, id, engine.Color{u8(tick), 2, 3})
				background: Maybe(engine.Color)
				if tick % 2 != 0 do background = engine.Color{4, 5, 6}
				engine.set_background(&e, id, background)
				if i == 0 do engine.set_symbol(&e, id, glyphs[(tick + 3) % len(glyphs)])
				engine.set_particle(&e, id, visible = tick % 5 != 0)
			}
			engine.frame_build(&e)
			for row in 0 ..< 2 {
				strings.builder_reset(&builder)
				for id in e.frame_particles[row * 65:(row + 1) * 65] {
					if id <
					   0 {strings.write_byte(&builder, ' ')} else {engine.write_particle(&e, id, &builder)}
				}
				testing.expect_value(t, string(e.row_bytes[row][:]), strings.to_string(builder))
			}
		}
	}
}
