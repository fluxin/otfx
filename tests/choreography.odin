package regression

import "../src/effects"
import "../src/engine"
import "core:math/rand"
import "core:mem"
import "core:strings"
import "core:testing"

@(test)
smoke_cloud_arrivals :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	for size in ([]engine.Coord{{1, 1}, {1, 40}, {40, 1}, {40, 12}}) {
		arrivals := make([]int, size.column * size.row)
		again := make([]int, len(arrivals))
		rand.reset_u64(42)
		effects.smoke_arrivals(arrivals, size.column)
		rand.reset_u64(42)
		effects.smoke_arrivals(again, size.column)
		latest := 0
		for arrival, i in arrivals {
			testing.expect_value(t, arrival, again[i])
			testing.expect(t, arrival >= 0 && arrival < len(arrivals))
			latest = max(latest, arrival)
			// Each new flood cell must touch an earlier frontier.
			connected := arrival == 0
			for offset, direction in ([4]int{-size.column, 1, size.column, -1}) {
				next := i + offset
				if next < 0 ||
				   next >= len(arrivals) ||
				   (direction == 1 && i % size.column == size.column - 1) ||
				   (direction == 3 && i % size.column == 0) {
					continue
				}
				connected ||= arrivals[next] == arrival - 1
			}
			testing.expect(t, connected)
		}
		if size.column > 1 && size.row > 1 {
			testing.expect(
				t,
				latest > size.column + size.row,
				"cloud paths must detour rather than form Manhattan chevrons",
			)
		}
	}
}

@(test)
smoke_symbols_span_the_gradient :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	for symbol_count in ([]int{3, 6}) {
		cfg := engine.config_default()
		cfg.ignore_terminal_dimensions = true
		e, err := engine.engine_make("X", cfg, context.allocator)
		testing.expect(t, err == .None)
		s := effects.Smoke_State {
			config = effects.smoke_config_default(),
		}
		clear(&s.config.smoke_gradient_stops)
		append(&s.config.smoke_gradient_stops, engine.Color{0, 0, 0})
		clear(&s.config.final_gradient_stops)
		append(&s.config.final_gradient_stops, engine.Color{255, 255, 255})
		clear(&s.config.smoke_symbols)
		symbols := []string{"a", "b", "c", "d", "e", "f"}
		append(&s.config.smoke_symbols, ..symbols[:symbol_count])
		effects.smoke_build(&s, &e)
		free_all(context.temp_allocator)
		expected :=
			symbol_count == 3 ? []string{"a", "a", "b", "c"} : []string{"a", "b", "c", "d", "e", "f"}
		id := s.characters[0]
		for symbol in expected {
			for _ in 0 ..< 3 {
				_, alive := effects.smoke_next(&s, &e)
				testing.expect(t, alive)
				testing.expect_value(t, e.chars.visual[id].symbol, symbol)
			}
		}
		for s.tick < s.last_tick do effects.smoke_next(&s, &e)
		testing.expect_value(t, e.chars.visual[id].symbol, "X")
		testing.expect_value(
			t,
			e.chars.visual[id].fg,
			Maybe(engine.Color)(engine.Color{255, 255, 255}),
		)
		_, alive := effects.smoke_next(&s, &e)
		testing.expect(t, !alive)
	}
}

@(test)
laseretch_order_is_spatial :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.ignore_terminal_dimensions = true
	for input in ([]string{"X", "A   B\n     \nC   D", strings.repeat("1234567890\n", 10)}) {
		e, err := engine.engine_make(input, cfg, context.allocator)
		testing.expect(t, err == .None)
		s := effects.Laseretch_State {
			config = effects.laseretch_config_default(),
		}
		rand.reset_u64(42)
		effects.laseretch_build(&s, &e)
		free_all(context.temp_allocator)
		seen := make([]bool, len(e.chars))
		testing.expect_value(t, len(s.pending), len(e.character_sets.input))
		adjacent := 0
		for id, i in s.pending {
			testing.expect(t, !seen[id] && !e.chars.is_fill[id])
			seen[id] = true
			if i == 0 do continue
			p, prev := e.chars.input_coord[id], e.chars.input_coord[s.pending[i - 1]]
			adjacent += int(abs(p.column - prev.column) + abs(p.row - prev.row) == 1)
		}
		if len(s.pending) == 100 do testing.expect(t, adjacent > 80, "depth-first etching must follow neighboring cells, not a shuffled population")
	}
	e, err := engine.engine_make("ABC\nDEF", cfg, context.allocator)
	testing.expect(t, err == .None)
	s := effects.Laseretch_State {
		config = effects.laseretch_config_default(),
	}
	s.config.etch_pattern = .Row_T2B
	effects.laseretch_build(&s, &e)
	for expected, i in ([]string{"A", "B", "C", "F", "E", "D"}) {
		testing.expect_value(t, e.chars.input_symbol[s.pending[i]], expected)
	}
	free_all(context.temp_allocator)
}

@(test)
burn_grows_a_connected_front :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make(strings.repeat("0123456789\n", 10), cfg, context.allocator)
	testing.expect(t, err == .None)
	s := effects.Burn_State {
		config = effects.burn_config_default(),
	}
	rand.reset_u64(42)
	effects.burn_build(&s, &e)
	free_all(context.temp_allocator)
	// Every ignition prefix must be one connected fire, rather than random
	// speckles across the input. Same-tick cells may connect through one another.
	for tick in 0 ..< s.last_fire_tick - len(s.fire_palette) * 4 - 36 + 1 {
		seen := make([]bool, len(s.characters))
		queue := make([dynamic]int, 0, len(s.characters))
		expected := 0
		for start, i in s.start_ticks {
			if start > tick do continue
			expected += 1
			if len(queue) == 0 {append(&queue, i); seen[i] = true}
		}
		for head := 0; head < len(queue); head += 1 {
			i := queue[head]
			p := e.chars.input_coord[s.characters[i]]
			for id, j in s.characters {
				q := e.chars.input_coord[id]
				if !seen[j] &&
				   s.start_ticks[j] <= tick &&
				   abs(p.column - q.column) + abs(p.row - q.row) == 1 {
					seen[j] = true
					append(&queue, j)
				}
			}
		}
		testing.expect_value(t, len(queue), expected)
	}
	// All nine fire glyphs appear in order, each in one consecutive run.
	run := 0
	order := effects.Burn_Char_Order
	for symbol, i in s.fire_symbols {
		if i > 0 && symbol != s.fire_symbols[i - 1] do run += 1
		testing.expect_value(t, symbol, order[run])
	}
	testing.expect_value(t, run, 8)
}

@(test)
laseretch_sparks_cool_during_flight :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 40, 50
	cfg.anchor_text = .N
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("AB", cfg, context.allocator)
	testing.expect(t, err == .None)
	s := effects.Laseretch_State {
		config = effects.laseretch_config_default(),
	}
	s.config.etch_delay, s.config.spark_cooling_frames = 1000, 2
	rand.reset_u64(42)
	effects.laseretch_build(&s, &e)
	free_all(context.temp_allocator)
	for _ in 0 ..< 3 do effects.laseretch_next(&s, &e)
	id := s.spark_ids[0]
	testing.expect(t, s.spark_steps[0] > 3)
	testing.expect_value(t, e.chars.visual[id].fg, Maybe(engine.Color)(s.spark_spectrum[1]))
	// Reclaim on color-scene completion even if the movement path is longer.
	for s.tick <= len(s.spark_spectrum) * 2 do effects.laseretch_next(&s, &e)
	testing.expect(t, !e.chars.is_visible[id])
	testing.expect_value(t, len(s.active_sparks), 0)
}
