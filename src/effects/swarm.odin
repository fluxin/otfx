package effects

import engine "../engine"

import "core:fmt"
import "core:math"
import "core:math/ease"
import "core:math/rand"
import "core:sort"

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

SWARM_FLASH_ENTRIES :: 26 // eight ramp entries, ten flash entries, eight returning

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
	flash_colors:       [dynamic]engine.Color,
	stage_stride:       int,
	group_area_stages:  [dynamic]int,
	group_spawns:       [dynamic]engine.Coord,
	group_start_ticks:  [dynamic]int,
	waypoints:          [dynamic]engine.Coord,
	lane_origins:       [dynamic]engine.Coord,
	lane_starts:        [dynamic]int,
	lane_ends:          [dynamic]int,
	lane_steps:         [dynamic]int,
	lane_next:          [dynamic]int,
	lane_finish:        [dynamic]int,
	character_stages:   [dynamic]int,
	active_indexes:     [dynamic]int,
	next_launch_group:  int,
	tick:               int,
	color_handling:     engine.Existing_Color_Handling,
}

Swarm_Plan_Event :: struct {
	tick:      int,
	character: int,
	stage:     int,
}

swarm_waypoint :: #force_inline proc(
	s: ^Swarm_State,
	character_index, stage: int,
) -> engine.Coord {
	return s.waypoints[character_index * s.stage_stride + stage]
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
	s.characters = engine.get_characters(query, engine.CHAR_FILTER_INPUT, .Top_Bottom_Left_Right)
	n := len(s.characters)
	s.stage_stride = s.config.swarm_area_count_range.hi * 3 + 1
	reserve(&s.active_indexes, n)
	s.color_handling = e.cfg.existing_color_handling
	s.index_by_id = make([dynamic]int, len(e.chars))
	s.final_colors = make([dynamic]engine.Color, n)
	s.waypoints = make([dynamic]engine.Coord, n * s.stage_stride)
	s.lane_origins = make([dynamic]engine.Coord, n * s.stage_stride)
	s.lane_starts = make([dynamic]int, n * s.stage_stride)
	s.lane_ends = make([dynamic]int, n * s.stage_stride)
	s.lane_steps = make([dynamic]int, n * s.stage_stride)
	s.lane_next = make([dynamic]int, n * s.stage_stride)
	s.lane_finish = make([dynamic]int, n)
	s.character_stages = make([dynamic]int, n)
	for &next in s.lane_next do next = -1

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
	for start := 0; start < n; start += swarm_size {
		end := min(start + swarm_size, n)
		span_start := len(s.swarms.members)
		append(&s.swarms.members, ..s.characters[start:end])
		append(&s.swarms.spans, engine.Span{span_start, end - start})
	}
	// Merge a tiny tail into the preceding contiguous group; every glyph plays.
	groups := len(s.swarms.spans)
	if groups > 1 {
		last := &s.swarms.spans[groups - 1]
		if last.len < math.floor_div(swarm_size, 2) {
			s.swarms.spans[groups - 2].len += last.len
			resize(&s.swarms.spans, groups - 1)
		}
	}
	groups = len(s.swarms.spans)
	s.group_stage_counts = make([dynamic]int, groups)
	s.flash_colors = make([dynamic]engine.Color, groups * SWARM_FLASH_ENTRIES)
	s.group_area_stages = make([dynamic]int, groups)
	s.group_spawns = make([dynamic]engine.Coord, groups)
	s.group_start_ticks = make([dynamic]int, groups)
	s.group_by_index = make([dynamic]int, n)

	for group in 0 ..< groups {
		for id in engine.group_members(s.swarms, group) do s.group_by_index[s.index_by_id[id]] = group
		area_count := rand.int_range(
			s.config.swarm_area_count_range.lo,
			s.config.swarm_area_count_range.hi + 1,
		)
		stages := area_count * 3 + 1
		s.group_stage_counts[group] = stages
		base_color := s.config.base_colors[rand.int_max(len(s.config.base_colors))]
		for entry in 0 ..< SWARM_FLASH_ENTRIES {
			step := entry < 8 ? entry : (entry < 18 ? 7 : 25 - entry)
			s.flash_colors[group * SWARM_FLASH_ENTRIES + entry] = engine.gradient_between_step(
				base_color,
				s.config.flash_color,
				7,
				step,
			)
		}
		spawn := engine.canvas_random_coord(e.canvas, true, false)
		s.group_spawns[group] = spawn
		area_radius := max(math.floor_div(min(e.canvas.right, e.canvas.top), 6), 1) * 2
		focus_radius := max(math.floor_div(min(e.canvas.right, e.canvas.top), 2), 1)
		area_coords := make([][dynamic]engine.Coord, area_count, context.temp_allocator)
		last_focus := spawn
		for area in 0 ..< area_count {
			// The source keeps each area around the *previous* focus, then
			// chooses the next focus from a large circle around it. That shared
			// area data is the coordination domain for every member of a swarm.
			circle := engine.find_coords_on_circle(last_focus, focus_radius, 0, false)
			rand.shuffle(circle[:])
			next_focus: engine.Coord
			found := false
			for p in circle {
				if engine.canvas_in(e.canvas, p) {
					next_focus, found = p, true
					break
				}
			}
			if !found do next_focus = engine.canvas_random_coord(e.canvas, false, false)
			delete(circle[:])
			area_coords[area] = engine.find_coords_in_circle(last_focus, area_radius)
			last_focus = next_focus
		}
		for id in engine.group_members(s.swarms, group) {
			i := s.index_by_id[id]
			current_coords[id] = spawn
			for area in 0 ..< area_count {
				base_stage := area * 3
				for inner in 0 ..< 3 {
					s.waypoints[i * s.stage_stride + base_stage + inner] =
						area_coords[area][rand.int_max(len(area_coords[area]))]
				}
			}
			s.waypoints[i * s.stage_stride + stages - 1] = input_coords[id]
		}
		for &coords in area_coords[:area_count] do delete(coords[:])
	}
	swarm_plan_lanes(s, e)
}

swarm_stage_speed :: #force_inline proc(stage, stage_count: int) -> f64 {
	if stage + 1 == stage_count do return 0.45
	return stage % 3 == 0 ? 0.4 : 0.18
}

swarm_stage_easing :: #force_inline proc(stage, stage_count: int) -> ease.Ease {
	if stage + 1 == stage_count do return .Quadratic_In_Out
	return stage % 3 == 0 ? .Sine_Out : .Sine_In_Out
}

swarm_lane_index :: #force_inline proc(s: ^Swarm_State, character, stage: int) -> int {
	return character * s.stage_stride + stage
}

swarm_event_less :: #force_inline proc(a, b: Swarm_Plan_Event) -> bool {
	return a.tick < b.tick || (a.tick == b.tick && a.character < b.character)
}

swarm_event_push :: proc(events: ^[dynamic]Swarm_Plan_Event, event: Swarm_Plan_Event) {
	append(events, event)
	i := len(events^) - 1
	for i > 0 {
		parent := (i - 1) / 2
		if !swarm_event_less(events^[i], events^[parent]) do break
		events^[i], events^[parent] = events^[parent], events^[i]
		i = parent
	}
}

swarm_event_pop :: proc(events: ^[dynamic]Swarm_Plan_Event) -> Swarm_Plan_Event {
	result := events^[0]
	last := pop(events)
	if len(events^) == 0 do return result
	events^[0] = last
	i := 0
	for {
		left := 2 * i + 1
		if left >= len(events^) do break
		smallest := left
		right := left + 1
		if right < len(events^) && swarm_event_less(events^[right], events^[left]) do smallest = right
		if !swarm_event_less(events^[smallest], events^[i]) do break
		events^[i], events^[smallest] = events^[smallest], events^[i]
		i = smallest
	}
	return result
}

swarm_lane_position :: proc(s: ^Swarm_State, character, stage, tick: int) -> engine.Coord {
	row := swarm_lane_index(s, character, stage)
	start := s.lane_starts[row]
	duration := s.lane_steps[row]
	progress := f64(clamp(tick - start, 0, duration)) / f64(duration)
	stage_count := s.group_stage_counts[s.group_by_index[character]]
	return engine.coord_on_line(
		s.lane_origins[row],
		swarm_waypoint(s, character, stage),
		ease.ease(swarm_stage_easing(stage, stage_count), progress),
	)
}

swarm_plan_segment :: proc(
	s: ^Swarm_State,
	character, stage, tick: int,
	origin: engine.Coord,
	events: ^[dynamic]Swarm_Plan_Event,
) {
	stage_count := s.group_stage_counts[s.group_by_index[character]]
	row := swarm_lane_index(s, character, stage)
	target := swarm_waypoint(s, character, stage)
	steps := max(
		engine.round_half_even(
			engine.line_length(origin, target, true) / swarm_stage_speed(stage, stage_count),
		),
		1,
	)
	s.lane_origins[row] = origin
	s.lane_starts[row] = tick
	s.lane_ends[row] = tick + steps
	s.lane_steps[row] = steps
	s.lane_next[row] = -1
	swarm_event_push(events, {tick + steps, character, stage})
}

swarm_plan_coordinate_area :: proc(
	s: ^Swarm_State,
	group, leader, stage, tick: int,
	plan_stages: []int,
	events: ^[dynamic]Swarm_Plan_Event,
) {
	group := s.group_by_index[leader]
	if stage <= s.group_area_stages[group] do return
	s.group_area_stages[group] = stage
	for id in engine.group_members(s.swarms, group) {
		i := s.index_by_id[id]
		if i == leader || plan_stages[i] < 0 || plan_stages[i] >= stage do continue
		if rand.float64() >= s.config.swarm_coordination do continue
		old_stage := plan_stages[i]
		old_row := swarm_lane_index(s, i, old_stage)
		s.lane_ends[old_row] = tick
		s.lane_next[old_row] = stage
		plan_stages[i] = stage
		swarm_plan_segment(s, i, stage, tick, swarm_lane_position(s, i, old_stage, tick), events)
	}
}

swarm_plan_group :: proc(s: ^Swarm_State, e: ^engine.Engine, group, start_tick: int) {
	plan_stages := make([]int, len(s.characters), context.temp_allocator)
	for &stage in plan_stages do stage = -1
	events: [dynamic]Swarm_Plan_Event
	defer delete(events[:])
	s.group_area_stages[group] = 0
	for id in engine.group_members(s.swarms, group) {
		i := s.index_by_id[id]
		plan_stages[i] = 0
		swarm_plan_segment(s, i, 0, start_tick, s.group_spawns[group], &events)
	}
	for len(events) > 0 {
		event := swarm_event_pop(&events)
		i, stage := event.character, event.stage
		row := swarm_lane_index(s, i, stage)
		if plan_stages[i] != stage || s.lane_ends[row] != event.tick do continue
		stage_count := s.group_stage_counts[group]
		if stage + 1 == stage_count {
			id := s.characters[i]
			style := e.chars.input_style[id]
			fade_ticks :=
				s.color_handling == .Dynamic && style.fg == nil && style.bg == nil ? 36 : 33
			s.lane_finish[i] = event.tick + fade_ticks
			plan_stages[i] = -1
			continue
		}
		next_stage := stage + 1
		s.lane_next[row] = next_stage
		plan_stages[i] = next_stage
		swarm_plan_segment(s, i, next_stage, event.tick, swarm_waypoint(s, i, stage), &events)
		if next_stage % 3 == 0 do swarm_plan_coordinate_area(s, group, i, next_stage, event.tick, plan_stages, &events)
	}
}

swarm_plan_lanes :: proc(s: ^Swarm_State, e: ^engine.Engine) {
	finish_ticks: [dynamic]int
	defer delete(finish_ticks[:])
	start_tick := 0
	launched := 0
	for group := len(s.swarms.spans) - 1; group >= 0; group -= 1 {
		s.group_start_ticks[group] = start_tick
		swarm_plan_group(s, e, group, start_tick)
		members := engine.group_members(s.swarms, group)
		for id in members do append(&finish_ticks, s.lane_finish[s.index_by_id[id]])
		launched += len(members)
		if group > 0 {
			finish_slice := finish_ticks[:]
			sort.sort(sort.slice_interface(&finish_slice))
			finished_needed := launched - len(members) + 1
			start_tick = finish_ticks[finished_needed - 1] + 1
		}
	}
	s.next_launch_group = len(s.swarms.spans) - 1
}

swarm_launch_group :: proc(s: ^Swarm_State, e: ^engine.Engine) {
	if s.next_launch_group < 0 do return
	group := s.next_launch_group
	s.next_launch_group -= 1
	for id in engine.group_members(s.swarms, group) {
		i := s.index_by_id[id]
		s.character_stages[i] = 0
		e.chars.current_coord[id] = s.lane_origins[swarm_lane_index(s, i, 0)]
		e.chars.is_visible[id] = true
		append(&s.active_indexes, i)
	}
}

swarm_next :: proc(s: ^Swarm_State, e: ^engine.Engine) -> ([]engine.Char_Id, bool) {
	for s.next_launch_group >= 0 && s.tick >= s.group_start_ticks[s.next_launch_group] do swarm_launch_group(s, e)
	if len(s.active_indexes) == 0 && s.next_launch_group < 0 do return nil, false

	current_coords := e.chars.current_coord
	input_symbols := e.chars.input_symbol
	visual_symbols := e.chars.visual
	visual_fg := e.chars.visual
	write := 0
	for i in s.active_indexes {
		group := s.group_by_index[i]
		stage_count := s.group_stage_counts[group]
		stage := s.character_stages[i]
		id := s.characters[i]
		row := swarm_lane_index(s, i, stage)
		// Coordination can replace a newly entered lane in the same tick.
		// Skip every expired lane before deciding between motion and landing.
		for s.tick >= s.lane_ends[row] && s.lane_next[row] >= 0 {
			stage = s.lane_next[row]
			s.character_stages[i] = stage
			row = swarm_lane_index(s, i, stage)
		}
		if s.tick >= s.lane_ends[row] {
			if s.tick >= s.lane_finish[i] {
				if s.color_handling == .Dynamic {
					engine.dynamic_apply_input_colors(&visual_fg[id], e.chars.input_style[id])
				} else {
					visual_fg[id].fg = s.final_colors[i]
				}
				continue
			}
			e.chars.layer[id] = 0
			landing_step := min((s.tick - s.lane_ends[row]) / 3, 10)
			if s.color_handling == .Dynamic {
				style := e.chars.input_style[id]
				if style.fg == nil && style.bg == nil && s.tick - s.lane_ends[row] >= 33 {
					visual_fg[id].fg = nil
				} else if fg, ok := style.fg.?; ok {
					visual_fg[id].fg = engine.gradient_between_step(
						s.config.flash_color,
						fg,
						10,
						landing_step,
					)
				} else if style.bg == nil {
					visual_fg[id].fg = engine.gradient_between_step(
						s.config.flash_color,
						engine.Color{0xff, 0xff, 0xff},
						10,
						landing_step,
					)
				} else {
					visual_fg[id].fg = nil
				}
				if bg, ok := style.bg.?; ok {
					visual_fg[id].bg = engine.gradient_between_step(
						s.config.flash_color,
						bg,
						10,
						landing_step,
					)
				} else {
					visual_fg[id].bg = nil
				}
			} else {
				visual_fg[id].fg = engine.gradient_between_step(
					s.config.flash_color,
					s.final_colors[i],
					10,
					landing_step,
				)
			}
			current_coords[id] = swarm_waypoint(s, i, stage)
			s.active_indexes[write] = i
			write += 1
			continue
		}
		if s.tick >= s.lane_starts[row] {
			progress := f64(s.tick - s.lane_starts[row] + 1) / f64(s.lane_steps[row])
			current_coords[id] = engine.coord_on_line(
				s.lane_origins[row],
				swarm_waypoint(s, i, stage),
				ease.ease(swarm_stage_easing(stage, stage_count), progress),
			)
			visual_symbols[id].symbol = input_symbols[id]
			e.chars.layer[id] = 1
			entry := 0
			if stage % 3 == 0 {
				// Entry and landing flash through a mirrored palette as distance
				// progresses. Inner paths retain the base color.
				distance_fraction := ease.ease(swarm_stage_easing(stage, stage_count), progress)
				entry = clamp(
					engine.round_half_even(f64(SWARM_FLASH_ENTRIES - 1) * distance_fraction),
					0,
					SWARM_FLASH_ENTRIES - 1,
				)
			}
			visual_fg[id].fg = s.flash_colors[group * SWARM_FLASH_ENTRIES + entry]
		}
		s.active_indexes[write] = i
		write += 1
	}
	resize(&s.active_indexes, write)
	s.tick += 1
	return s.characters[:], true
}
