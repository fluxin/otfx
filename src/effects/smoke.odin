package effects

import engine "../engine"

import "core:fmt"
import "core:math/rand"

Smoke_Config :: struct {
	starting_color:           engine.Color,
	smoke_symbols:            [dynamic]string,
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
	append(&cfg.smoke_symbols, ..[]string{"░", "▒", "▓", "▒", "░"})
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
			cfg.use_whole_canvas = true
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
	characters:     [dynamic]engine.Char_Id,
	arrivals:       [dynamic]int,
	previous:       [dynamic]int,
	changes:        [dynamic]engine.Sample_Change,
	samples:        [dynamic]int,
	final_colors:   [dynamic]engine.Color,
	smoke_palette:  [dynamic]engine.Color,
	smoke_symbols:  [dynamic]string,
	paint_pairs:    [dynamic]int,
	paint_steps:    [dynamic]int,
	tick:           int,
	last_tick:      int,
	color_handling: engine.Existing_Color_Handling,
}

// Generate Python's weighted Prim tree once, then retain only BFS arrival
// ticks. Cells are row-major, top to bottom. Four bits encode tree neighbors;
// equal-weight candidate edges share flat buckets with random removal.
smoke_arrivals :: proc(arrivals: []int, width: int) {
	n := len(arrivals)
	if n == 0 do return
	context.allocator = context.temp_allocator
	weights := make([]u8, n)
	links := make([]u8, n)
	visited := make([]bool, n)
	buckets: [100]engine.Span
	current := rand.int_max(n)
	for &weight in weights {
		weight = u8(rand.int_max(100))
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
	edges := make([]Edge, 4 * n)
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
		}
		found := false
		for &bucket in buckets {
			for bucket.len > 0 {
				pick := rand.int_max(bucket.len)
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
	queue := make([]int, n)
	for &arrival in arrivals do arrival = -1
	root := rand.int_max(n)
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
	append(&stops, ..s.config.smoke_gradient_stops[:])
	for i := len(s.config.final_gradient_stops) - 1; i >= 0; i -= 1 do append(&stops, s.config.final_gradient_stops[i])
	palette := engine.gradient_make(stops[:], []int{3, 4}, false)
	defer delete(palette[:])
	// Distribute the shorter lane evenly, with the remainder at the front,
	// just like Python's apply_gradient_to_symbols (including long symbol lists).
	entries := max(len(palette), len(s.config.smoke_symbols))
	s.smoke_palette = engine.sequence_expand(palette[:], entries)
	s.smoke_symbols = engine.sequence_expand(s.config.smoke_symbols[:], entries)

	query := engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas}
	// Smoke always needs the text rectangle, including its spaces. The
	// whole-canvas option expands that population with outer fill cells.
	filter := engine.Character_Filter{.Input, .Inner_Fill}
	if s.config.use_whole_canvas do filter += {.Outer_Fill}
	s.characters = engine.get_characters(query, filter, .Top_Bottom_Left_Right)
	n := len(s.characters)
	s.arrivals = make([dynamic]int, n)
	s.final_colors = make([dynamic]engine.Color, n)

	width := s.config.use_whole_canvas ? e.canvas.width : e.canvas.text_width
	smoke_arrivals(s.arrivals[:], width)
	input_coords := e.chars.input_coord
	visual_fg := e.chars.visual
	visible := e.chars.is_visible
	for id, i in s.characters {
		p := input_coords[id]
		s.last_tick = max(s.last_tick, s.arrivals[i])
		s.final_colors[i] = engine.gradient_sample(final_sampler, final_spectrum[:], p)
		if s.color_handling == .Dynamic {
			visual_fg[id].fg = engine.Color{0x00, 0x00, 0x00}
			visual_fg[id].bg = nil
		} else {
			visual_fg[id].fg = s.config.starting_color
		}
		visible[id] = true
	}

	// smoke frames last 3 ticks; final paint is a 5-tick gradient across every
	// configured stop and then the character-specific destination color.
	paint_entries := 1 + 5 * len(s.config.final_gradient_stops)
	s.paint_pairs = make([dynamic]int, paint_entries)
	s.paint_steps = make([dynamic]int, paint_entries)
	pair, step := 0, 0
	for i in 0 ..< paint_entries {
		s.paint_pairs[i] = pair
		s.paint_steps[i] = step
		step += 1
		if step == 6 {
			pair += 1
			step = 1
		}
	}
	if s.color_handling == .Dynamic {
		s.last_tick += len(s.config.smoke_symbols) * 10 + 5
	} else {
		s.last_tick += len(s.smoke_palette) * 3 + paint_entries * 5
	}
	// Store one shared clock across smoke and paint, including their different
	// hold durations. Character-specific colors are computed only on changes.
	s.previous = make([dynamic]int, n)
	s.changes = make([dynamic]engine.Sample_Change, n)
	for &sample in s.previous do sample = -1
	smoke_count :=
		s.color_handling == .Dynamic ? len(s.config.smoke_symbols) : len(s.smoke_palette)
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
) -> engine.Color {
	// Gradient(stops..., end, steps=5), sampled from build-time lookup rows so
	// the dense per-character loop only performs direct indexed loads.
	start := stops[pair]
	finish := pair + 1 < len(stops) ? stops[pair + 1] : end
	return engine.gradient_between_step(start, finish, 5, step)
}

smoke_next :: proc(s: ^Smoke_State, e: ^engine.Engine) -> ([]engine.Char_Id, bool) {
	if s.tick == s.last_tick do return nil, false
	smoke_count :=
		s.color_handling == .Dynamic ? len(s.config.smoke_symbols) : len(s.smoke_palette)
	changes := engine.sample_timeline_changes(
		s.changes[:],
		s.arrivals[:],
		s.previous[:],
		s.tick,
		s.samples[:],
	)
	for change in changes {
		i, sample := change.slot, change.sample
		id := s.characters[i]
		if sample < smoke_count {
			if s.color_handling == .Dynamic {
				e.chars.visual[id].symbol = s.config.smoke_symbols[sample]
				engine.dynamic_apply_input_colors(&e.chars.visual[id], e.chars.input_style[id])
			} else {
				e.chars.visual[id].symbol = s.smoke_symbols[sample]
				e.chars.visual[id].fg = s.smoke_palette[sample]
			}
		} else {
			e.chars.visual[id].symbol = e.chars.input_symbol[id]
			if s.color_handling == .Dynamic {
				engine.dynamic_apply_input_colors(&e.chars.visual[id], e.chars.input_style[id])
			} else {
				paint_entry := sample - smoke_count
				e.chars.visual[id].fg = smoke_paint_color(
					s.config.final_gradient_stops[:],
					s.final_colors[i],
					s.paint_pairs[paint_entry],
					s.paint_steps[paint_entry],
				)
			}
		}
	}
	s.tick += 1
	return s.characters[:], true
}
