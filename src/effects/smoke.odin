package effects

import engine "../engine"

import "core:fmt"

Smoke_Config :: struct {
	starting_color:           engine.Color,
	smoke_symbols:            [dynamic]rune,
	smoke_gradient_stops:     [dynamic]engine.Color,
	use_whole_canvas:         bool,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

smoke_config_default :: proc() -> Smoke_Config {
	cfg := Smoke_Config {
		starting_color           = engine.Color{0x7A, 0x7A, 0x7A},
		final_gradient_direction = .Vertical,
	}
	append(&cfg.smoke_symbols, ..[]rune{'░', '▒', '▓', '▒', '░'})
	append(
		&cfg.smoke_gradient_stops,
		engine.Color{0x24, 0x24, 0x24},
		engine.Color{0xFF, 0xFF, 0xFF},
	)
	append(
		&cfg.final_gradient_stops,
		..[]engine.Color {
			engine.Color{0x8A, 0x00, 0x8A},
			engine.Color{0x00, 0xD1, 0xFF},
			engine.Color{0xFF, 0xFF, 0xFF},
		},
	)
	append(&cfg.final_gradient_steps, 12)
	return cfg
}

smoke_parse :: proc(cfg: ^Smoke_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--starting-color":
			if !parse_color_flag(&cfg.starting_color, args, &i, value, has_value) do return false
		case "--smoke-symbols":
			if !parse_symbols_flag(&cfg.smoke_symbols, args, &i, value, has_value) do return false
		case "--smoke-gradient-stops":
			if !parse_colors_flag(&cfg.smoke_gradient_stops, args, &i, value, has_value) do return false
		case "--use-whole-canvas":
			if !parse_bool_flag(&cfg.use_whole_canvas, has_value) do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown smoke option: ", name)
			return false
		}
	}
	return true
}

// `arrivals[i]` is the flood-front tick for `characters[i]`. The text starts
// visible and the front replaces its glyph with smoke before restoring it
// through the final palette. There are no per-character scenes or graph maps.
Smoke_State :: struct {
	config:         Smoke_Config,
	characters:     [dynamic]engine.Particle_Id,
	arrivals:       [dynamic]int, // nondecreasing: characters are in flood order
	previous:       [dynamic]int,
	settled:        int, // characters[:settled] hold their final sample
	arrived:        int, // characters[:arrived] have been reached by the flood
	changes:        [dynamic]engine.Sample_Change,
	samples:        [dynamic]int,
	style_slots:    [dynamic]int,
	smoke_codes:    [dynamic]engine.Appearance_Id,
	smoke_symbols:  [dynamic]rune,
	paint_ramp:     engine.Appearance_Ramp,
	dynamic_codes:  [dynamic]engine.Appearance_Id,
	tick:           int,
	last_tick:      int,
	color_handling: engine.Existing_Color_Handling,
}

// Generate Python's weighted Prim tree once, then retain only BFS arrival
// ticks. Cells are row-major, top to bottom. Four bits encode tree neighbors;
// equal-weight candidate edges share flat buckets with random removal.
// `order` receives the cells in BFS order, so their arrivals never decrease.
smoke_arrivals :: proc(arrivals, order: []int, width: int) #no_bounds_check {
	n := len(arrivals)
	if n == 0 do return
	weights := make([]u8, n, context.temp_allocator)
	links := make([]u8, n, context.temp_allocator)
	visited := make([]bool, n, context.temp_allocator)
	defer delete(weights, context.temp_allocator)
	defer delete(links, context.temp_allocator)
	defer delete(visited, context.temp_allocator)
	buckets: [100]engine.Span
	lowest := len(buckets) // no bucket below this one holds an edge
	current := engine.random_below(n)
	for &weight in weights {
		weight = u8(engine.random_below(100))
		buckets[weight].len += 4
	}
	start := 0
	for &bucket in buckets {
		bucket.start = start
		start += bucket.len
		bucket.len = 0
	}
	Edge :: struct {
		source, direction: int,
	}
	edges := make([]Edge, 4 * n, context.temp_allocator)
	defer delete(edges, context.temp_allocator)
	offsets := [4]int{-width, 1, width, -1}
	visited[current] = true
	for {
		column := current % width
		for offset, direction in offsets {
			next := current + offset
			if next < 0 ||
			   next >= n ||
			   (direction == 1 && column == width - 1) ||
			   (direction == 3 && column == 0) ||
			   visited[next] {
				continue
			}
			bucket := &buckets[weights[next]]
			edges[bucket.start + bucket.len] = {current, direction}
			bucket.len += 1
			lowest = min(lowest, int(weights[next]))
		}
		found := false
		for ; lowest < len(buckets); lowest += 1 {
			bucket := &buckets[lowest]
			for bucket.len > 0 {
				pick := engine.random_below(bucket.len)
				edge := edges[bucket.start + pick]
				bucket.len -= 1
				edges[bucket.start + pick] = edges[bucket.start + bucket.len]
				next := edge.source + offsets[edge.direction]
				if visited[next] do continue
				links[edge.source] |= 1 << u8(edge.direction)
				links[next] |= 1 << u8((edge.direction + 2) % 4)
				visited[next] = true
				current, found = next, true
				break
			}
			if found do break
		}
		if !found do break
	}
	queue := order
	for &arrival in arrivals do arrival = -1
	root := engine.random_below(n)
	queue[0], arrivals[root] = root, 0
	tail := 1
	for head := 0; head < tail; head += 1 {
		cell := queue[head]
		for offset, direction in offsets {
			if links[cell] & (1 << u8(direction)) == 0 do continue
			next := cell + offset
			if arrivals[next] >= 0 do continue
			arrivals[next] = arrivals[cell] + 1
			queue[tail] = next
			tail += 1
		}
	}
	// Python steps the first BFS layer before emitting its first frame.
	for &arrival in arrivals do arrival = max(arrival - 1, 0)
}

smoke_build :: proc(s: ^Smoke_State, e: ^engine.Engine) {
	s.color_handling = e.cfg.existing_color_handling
	final_spectrum := engine.gradient_make(
		s.config.final_gradient_stops[:],
		s.config.final_gradient_steps[:],
		false,
	)
	defer delete(final_spectrum[:])
	final_sampler := engine.gradient_sampler(
		e.canvas.text_bottom,
		e.canvas.text_top,
		e.canvas.text_left,
		e.canvas.text_right,
		s.config.final_gradient_direction,
	)

	// Gradient(smoke stops, reversed final stops, steps=(3, 4)). `gradient_make`
	// repeats the final step count over later pairs, matching that construction.
	stops := make(
		[dynamic]engine.Color,
		0,
		len(s.config.smoke_gradient_stops) + len(s.config.final_gradient_stops),
		context.temp_allocator,
	)
	defer delete(stops)
	append(&stops, ..s.config.smoke_gradient_stops[:])
	for i := len(s.config.final_gradient_stops) - 1; i >= 0; i -= 1 do append(&stops, s.config.final_gradient_stops[i])
	palette := engine.gradient_make(stops[:], []int{3, 4}, false)
	defer delete(palette[:])
	// Distribute the shorter lane evenly, with the remainder at the front,
	// just like Python's apply_gradient_to_symbols (including long symbol lists).
	entries := max(len(palette), len(s.config.smoke_symbols))
	smoke_palette := engine.sequence_expand(palette[:], entries)
	defer delete(smoke_palette)
	s.smoke_symbols = engine.sequence_expand(s.config.smoke_symbols[:], entries)
	s.smoke_codes = make([dynamic]engine.Appearance_Id, len(smoke_palette))
	for color, k in smoke_palette {
		s.smoke_codes[k] = engine.prepare_appearance(e, engine.Appearance{colors = {fg = color}})
	}

	query := engine.Particle_Query {
		e.particle_sets,
		e.particles.initial_coord[:len(e.particles)],
		e.canvas,
	}
	// Smoke always needs the text rectangle, including its spaces. The
	// whole-canvas option expands that population with outer fill cells.
	filter := engine.Particle_Filter{.Input, .Inner_Fill}
	if s.config.use_whole_canvas do filter += {.Outer_Fill}
	cells := engine.get_particles(query, filter, .Top_Bottom_Left_Right)
	defer delete(cells)
	n := len(cells)
	width := s.config.use_whole_canvas ? e.canvas.width : e.canvas.text_width
	arrivals := make([]int, n, context.temp_allocator)
	order := make([]int, n, context.temp_allocator)
	defer delete(arrivals, context.temp_allocator)
	defer delete(order, context.temp_allocator)
	smoke_arrivals(arrivals, order, width)
	// Store characters in flood order: the animating ones form one window.
	s.characters = make([dynamic]engine.Particle_Id, n)
	s.arrivals = make([dynamic]int, n)
	for cell, i in order {
		s.characters[i] = cells[cell]
		s.arrivals[i] = arrivals[cell]
	}

	starting_code := engine.prepare_appearance(
		e,
		engine.Appearance {
			colors = {
				fg = s.color_handling == .Dynamic ? engine.Color{0x00, 0x00, 0x00} : s.config.starting_color,
			},
		},
	)
	initial_coords := e.particles.initial_coord
	visible_flags := e.particles.flags
	final_colors := make([]engine.Color, n, context.temp_allocator)
	defer delete(final_colors, context.temp_allocator)
	for id, i in s.characters {
		p := initial_coords[id]
		s.last_tick = max(s.last_tick, s.arrivals[i])
		final_colors[i] = engine.gradient_sample(final_sampler, final_spectrum[:], p)
		engine.set_appearance(e, id, starting_code)
		visible_flags[id] += {.Visible}
	}

	// smoke frames last 3 ticks; final paint is a 5-tick gradient across every
	// configured stop and then the character-specific destination color.
	paint_entries := 1 + 5 * len(s.config.final_gradient_stops)
	if s.color_handling == .Dynamic {
		dyn_pairs := make([]engine.Color_Pair, n, context.temp_allocator)
		defer delete(dyn_pairs, context.temp_allocator)
		for id, i in s.characters {
			dyn_pairs[i] = engine.get_initial_appearance(e, engine.Particle_Id(id)).colors
		}
		unique_pairs: [dynamic]engine.Color_Pair
		unique_pairs, s.style_slots = engine.group_values(dyn_pairs)
		defer delete(unique_pairs)
		s.dynamic_codes = make([dynamic]engine.Appearance_Id, len(unique_pairs))
		for pair, g in unique_pairs {
			s.dynamic_codes[g] = engine.prepare_appearance(e, engine.Appearance{colors = pair})
		}
		s.last_tick += len(s.config.smoke_symbols) * 10 + 5
	} else {
		unique_finals: [dynamic]engine.Color
		unique_finals, s.style_slots = engine.group_values(final_colors)
		defer delete(unique_finals)
		paint_styles := make([]engine.Appearance, len(unique_finals) * paint_entries, context.temp_allocator)
		defer delete(paint_styles, context.temp_allocator)
		for final, g in unique_finals {
			pair, step := 0, 0
			for entry in 0 ..< paint_entries {
				paint_styles[g * paint_entries + entry] = {
					colors = {fg = smoke_paint_color(s.config.final_gradient_stops[:], final, pair, step)},
				}
				step += 1
				if step == 6 {
					pair += 1
					step = 1
				}
			}
		}
		s.paint_ramp = engine.ramp_from_styles(e, paint_styles, paint_entries - 1)
		s.last_tick += len(s.smoke_codes) * 3 + paint_entries * 5
	}
	// Store one shared clock across smoke and paint, including their different
	// hold durations. Particle-specific colors are computed only on changes.
	s.previous = make([dynamic]int, n)
	s.changes = make([dynamic]engine.Sample_Change, n)
	for &sample in s.previous do sample = -1
	smoke_count :=
		s.color_handling == .Dynamic ? len(s.config.smoke_symbols) : len(s.smoke_codes)
	smoke_hold := s.color_handling == .Dynamic ? 10 : 3
	paint_count := s.color_handling == .Dynamic ? 1 : paint_entries
	s.samples = make([dynamic]int, smoke_count * smoke_hold + paint_count * 5)
	for &sample, tick in s.samples {
		sample =
			tick < smoke_count * smoke_hold ? tick / smoke_hold : smoke_count + (tick - smoke_count * smoke_hold) / 5
	}
}

smoke_paint_color :: proc(
	stops: []engine.Color,
	end: engine.Color,
	pair, step: int,
) -> engine.Color #no_bounds_check {
	// Gradient(stops..., end, steps=5), sampled at build time into `paint_ramp`.
	start := stops[pair]
	finish := pair + 1 < len(stops) ? stops[pair + 1] : end
	return engine.tween(start, finish, 5, step)
}

smoke_next :: proc(s: ^Smoke_State, e: ^engine.Engine) -> bool #no_bounds_check {
	if s.tick == s.last_tick do return false
	smoke_count :=
		s.color_handling == .Dynamic ? len(s.config.smoke_symbols) : len(s.smoke_codes)
	for s.arrived < len(s.arrivals) && s.arrivals[s.arrived] <= s.tick do s.arrived += 1
	changes := engine.sample_timeline_changes(
		s.changes[:],
		s.arrivals[s.settled:s.arrived],
		s.previous[s.settled:s.arrived],
		s.tick,
		s.samples[:],
	)
	for change in changes {
		i, sample := s.settled + change.slot, change.sample
		id := s.characters[i]
		if sample < smoke_count {
			if s.color_handling == .Dynamic {
				engine.set_symbol(e, id, s.config.smoke_symbols[sample])
				engine.set_appearance(e, id, s.dynamic_codes[s.style_slots[i]])
			} else {
				engine.set_symbol(e, id, s.smoke_symbols[sample])
				engine.set_appearance(e, id, s.smoke_codes[sample])
			}
		} else {
			engine.set_symbol(e, id, e.particles.initial_symbol[engine.Particle_Id(id)])
			if s.color_handling == .Dynamic {
				engine.set_appearance(e, id, s.dynamic_codes[s.style_slots[i]])
			} else {
				engine.set_appearance(
					e,
					id,
					engine.ramp_code(s.paint_ramp, s.style_slots[i], sample - smoke_count),
				)
			}
		}
	}
	final_sample := s.samples[len(s.samples) - 1]
	for s.settled < s.arrived && s.previous[s.settled] == final_sample do s.settled += 1
	s.tick += 1
	return true
}
