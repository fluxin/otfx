package effects

import engine "../engine"

import "core:fmt"
import "core:math"
import rand "core:math/rand"

Swarm_Config :: struct {
	base_colors:              [dynamic]engine.Color,
	flash_color:              engine.Color,
	swarm_size:               f64,
	swarm_coordination:       f64,
	swarm_area_count_range:   Int_Range_Value,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

swarm_config_default :: proc() -> Swarm_Config {
	cfg := Swarm_Config {
		flash_color              = engine.Color{0xF2, 0xEA, 0x79},
		swarm_size               = 0.1,
		swarm_coordination       = 0.8,
		swarm_area_count_range   = {2, 4},
		final_gradient_direction = .Horizontal,
	}
	append(&cfg.base_colors, engine.Color{0x31, 0xA0, 0xD4})
	append(
		&cfg.final_gradient_stops,
		engine.Color{0x31, 0xB9, 0x00},
		engine.Color{0xF0, 0xFF, 0x65},
	)
	append(&cfg.final_gradient_steps, 12)
	return cfg
}

swarm_parse :: proc(cfg: ^Swarm_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--base-color":
			if !parse_colors_flag(&cfg.base_colors, args, &i, value, has_value) do return false
		case "--flash-color":
			if !parse_color_flag(&cfg.flash_color, args, &i, value, has_value) do return false
		case "--swarm-size":
			if !parse_float_flag(&cfg.swarm_size, args, &i, value, has_value) || cfg.swarm_size < 0 || cfg.swarm_size > 1 do return false
		case "--swarm-coordination":
			if !parse_float_flag(&cfg.swarm_coordination, args, &i, value, has_value) || cfg.swarm_coordination < 0 || cfg.swarm_coordination > 1 do return false
		case "--swarm-area-count-range":
			if !parse_int_range_flag(&cfg.swarm_area_count_range, args, &i, value, has_value) || cfg.swarm_area_count_range.lo <= 0 do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown swarm option: ", name)
			return false
		}
	}
	return true
}

SWARM_MAX_STAGES :: 13 // four areas × (enter + two inner moves), then land

// A swarm is a contiguous slice, while each source glyph owns a fixed-width
// waypoint row. Only the currently active swarm is touched per frame.
Swarm_State :: struct {
	config:             Swarm_Config,
	characters:         [dynamic]engine.Char_Id,
	index_by_id:        [dynamic]int,
	group_by_index:     [dynamic]int,
	final_colors:       [dynamic]engine.Color,
	swarms:             engine.Char_Groups,
	group_stage_counts: [dynamic]int,
	group_colors:       [dynamic]engine.Color,
	waypoints:          [dynamic]engine.Coord,
	segment_origins:    [dynamic]engine.Coord,
	segment_steps:      [dynamic]int,
	segment_lags:       [dynamic]int,
	character_stages:   [dynamic]int,
	character_ticks:    [dynamic]int,
	active_indexes:     [dynamic]int,
	next_group:         int,
}

swarm_waypoint :: #force_inline proc(
	s: ^Swarm_State,
	character_index, stage: int,
) -> engine.Coord {
	return s.waypoints[character_index * SWARM_MAX_STAGES + stage]
}

swarm_build :: proc(s: ^Swarm_State, e: ^engine.Engine) {
	spectrum := engine.gradient_make(
		s.config.final_gradient_stops[:],
		s.config.final_gradient_steps[:],
		false,
	)
	defer delete(spectrum[:])
	sampler := engine.gradient_sampler(
		e.canvas.text_bottom,
		e.canvas.text_top,
		e.canvas.text_left,
		e.canvas.text_right,
		s.config.final_gradient_direction,
	)
	query := engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas}
	s.characters = engine.get_characters(query, engine.filter_input(), .Top_Bottom_Left_Right)
	n := len(s.characters)
	s.index_by_id = make([dynamic]int, len(e.chars))
	s.final_colors = make([dynamic]engine.Color, n)
	s.waypoints = make([dynamic]engine.Coord, n * SWARM_MAX_STAGES)
	s.segment_origins = make([dynamic]engine.Coord, n)
	s.segment_steps = make([dynamic]int, n)
	s.segment_lags = make([dynamic]int, n)
	s.character_stages = make([dynamic]int, n)
	s.character_ticks = make([dynamic]int, n)

	input_coords := e.chars.input_coord
	current_coords := e.chars.current_coord
	visible := e.chars.is_visible
	for id, i in s.characters {
		s.index_by_id[id] = i
		s.final_colors[i] = engine.gradient_sample(sampler, spectrum[:], input_coords[id])
		visible[id] = false
		current_coords[id] = engine.canvas_random_coord(e.canvas, true, false)
	}

	swarm_size := max(engine.round_half_even(f64(n) * s.config.swarm_size), 1)
	append(&s.swarms.offsets, 0)
	for start := 0; start < n; start += swarm_size {
		end := min(start + swarm_size, n)
		append(&s.swarms.chars, ..s.characters[start:end])
		append(&s.swarms.offsets, len(s.swarms.chars))
	}
	// Merge a tiny final group, matching the reference effect's visible rhythm.
	groups := engine.group_count(s.swarms)
	if groups > 1 {
		last_count := s.swarms.offsets[groups] - s.swarms.offsets[groups - 1]
		if last_count < math.floor_div(swarm_size, 2) do resize(&s.swarms.offsets, groups)
	}
	groups = engine.group_count(s.swarms)
	s.group_stage_counts = make([dynamic]int, groups)
	s.group_colors = make([dynamic]engine.Color, groups)
	s.group_by_index = make([dynamic]int, n)

	for group in 0 ..< groups {
		for id in engine.group_slice(s.swarms, group) do s.group_by_index[s.index_by_id[id]] = group
		area_count := rand.int_range(
			s.config.swarm_area_count_range.lo,
			s.config.swarm_area_count_range.hi + 1,
		)
		area_count = min(area_count, 4)
		stages := area_count * 3 + 1
		s.group_stage_counts[group] = stages
		s.group_colors[group] = s.config.base_colors[rand.int_max(len(s.config.base_colors))]
		spawn := engine.canvas_random_coord(e.canvas, true, false)
		focus := engine.canvas_random_coord(e.canvas, false, false)
		radius := max(math.floor_div(min(e.canvas.width, e.canvas.height), 6), 1)
		for id in engine.group_slice(s.swarms, group) {
			i := s.index_by_id[id]
			current_coords[id] = spawn
			for area in 0 ..< area_count {
				if area > 0 {
					focus = engine.coord(
						clamp(
							focus.column + rand.int_range(-radius * 2, radius * 2 + 1),
							e.canvas.left,
							e.canvas.right,
						),
						clamp(
							focus.row + rand.int_range(-radius, radius + 1),
							e.canvas.bottom,
							e.canvas.top,
						),
					)
				}
				base_stage := area * 3
				for inner in 0 ..< 3 {
					s.waypoints[i * SWARM_MAX_STAGES + base_stage + inner] = engine.coord(
						clamp(
							focus.column + rand.int_range(-radius, radius + 1),
							e.canvas.left,
							e.canvas.right,
						),
						clamp(
							focus.row +
							rand.int_range(-max(radius / 2, 1), max(radius / 2, 1) + 1),
							e.canvas.bottom,
							e.canvas.top,
						),
					)
				}
			}
			s.waypoints[i * SWARM_MAX_STAGES + stages - 1] = input_coords[id]
		}
	}
	s.next_group = groups - 1
}

swarm_stage_speed :: #force_inline proc(stage, stage_count: int) -> f64 {
	if stage + 1 == stage_count do return 0.45
	return stage % 3 == 0 ? 0.4 : 0.18
}

swarm_begin_segment :: proc(s: ^Swarm_State, e: ^engine.Engine, i: int) {
	current_coords := e.chars.current_coord
	id := s.characters[i]
	stage := s.character_stages[i]
	stage_count := s.group_stage_counts[s.group_by_index[i]]
	s.segment_origins[i] = current_coords[id]
	target := swarm_waypoint(s, i, stage)
	s.segment_steps[i] = max(
		engine.round_half_even(
			engine.line_length(s.segment_origins[i], target, true) /
			swarm_stage_speed(stage, stage_count),
		),
		1,
	)
	// The reference starts each group together, then lets the path chain fan
	// out. A small initial lag gives the uncoordinated minority that same look.
	s.segment_lags[i] = rand.float64() < s.config.swarm_coordination ? 0 : rand.int_range(1, 13)
	s.character_ticks[i] = 0
}

swarm_launch_group :: proc(s: ^Swarm_State, e: ^engine.Engine) {
	if s.next_group < 0 do return
	group := s.next_group
	s.next_group -= 1
	visible := e.chars.is_visible
	for id in engine.group_slice(s.swarms, group) {
		i := s.index_by_id[id]
		s.character_stages[i] = 0
		swarm_begin_segment(s, e, i)
		visible[id] = true
		append(&s.active_indexes, i)
	}
}

swarm_next :: proc(s: ^Swarm_State, e: ^engine.Engine) -> bool {
	if len(s.active_indexes) == 0 && s.next_group < 0 do return false
	if len(s.active_indexes) == 0 do swarm_launch_group(s, e)

	current_coords := e.chars.current_coord
	input_symbols := e.chars.input_symbol
	visual_symbols := e.chars.visual_symbol
	visual_fg := e.chars.visual_fg
	write := 0
	launch_next := false
	for i in s.active_indexes {
		group := s.group_by_index[i]
		stage_count := s.group_stage_counts[group]
		stage := s.character_stages[i]
		id := s.characters[i]
		age := s.character_ticks[i] - s.segment_lags[i]
		if age >= 0 {
			progress := f64(min(age + 1, s.segment_steps[i])) / f64(s.segment_steps[i])
			current_coords[id] = engine.coord_on_line(
				s.segment_origins[i],
				swarm_waypoint(s, i, stage),
				engine.easing_apply(
					stage + 1 == stage_count ? engine.ease_of(.Quadratic_In_Out) : engine.ease_of(.Sine_In_Out),
					progress,
				),
			)
			visual_symbols[id] = input_symbols[id]
			if stage + 1 == stage_count {
				visual_fg[id] = engine.gradient_between_step(
					s.config.flash_color,
					s.final_colors[i],
					10,
					min(age / 3, 10),
				)
			} else {
				flash_step := min(age, 6)
				visual_fg[id] = engine.gradient_between_step(
					s.group_colors[group],
					s.config.flash_color,
					6,
					flash_step,
				)
			}
		}
		s.character_ticks[i] += 1
		if s.character_ticks[i] < s.segment_steps[i] + s.segment_lags[i] {
			s.active_indexes[write] = i
			write += 1
			continue
		}

		current_coords[id] = swarm_waypoint(s, i, stage)
		if stage + 1 == stage_count {
			visual_fg[id] = s.final_colors[i]
			// ttfx starts the following swarm as soon as the first character in
			// this group has finished its chained motion. Keeping the older
			// members active lets the swarms overlap instead of serializing them.
			launch_next = true
		} else {
			s.character_stages[i] += 1
			swarm_begin_segment(s, e, i)
			s.active_indexes[write] = i
			write += 1
		}
	}
	resize(&s.active_indexes, write)
	if launch_next do swarm_launch_group(s, e)
	engine.frame(e, s.characters[:])
	return true
}
