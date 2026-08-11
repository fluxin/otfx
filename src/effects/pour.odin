package effects

import engine "../engine"
import rand "core:math/rand"

import "core:fmt"

// pour — characters pour in from one edge, group by group. Groups live in one
// flat pool; the group being poured is a span into it.

Pour_Direction :: enum {
	Up,
	Down,
	Left,
	Right,
}

Pour_Config :: struct {
	pour_direction:           Pour_Direction,
	pour_speed:               int,
	movement_speed_range:     Float_Range_Value,
	gap:                      int,
	starting_color:           engine.Color,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_frames:    int,
	final_gradient_direction: engine.Gradient_Direction,
	movement_easing:          engine.Easing,
}

pour_config_default :: proc() -> Pour_Config {
	cfg := Pour_Config {
		pour_direction           = .Down,
		pour_speed               = 2,
		movement_speed_range     = {0.4, 0.6},
		gap                      = 1,
		starting_color           = engine.Color{0xff, 0xff, 0xff},
		final_gradient_frames    = 6,
		final_gradient_direction = .Vertical,
		movement_easing          = engine.ease_of(.Quadratic_In),
	}
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

pour_parse :: proc(cfg: ^Pour_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--pour-direction":
			v, ok := opt_value(args, &i, value, has_value)
			if !ok do return false
			switch v {
			case "up":
				cfg.pour_direction = .Up
			case "down":
				cfg.pour_direction = .Down
			case "left":
				cfg.pour_direction = .Left
			case "right":
				cfg.pour_direction = .Right
			case:
				return false
			}
		case "--pour-speed":
			if !parse_int_flag(&cfg.pour_speed, args, &i, value, has_value) do return false
		case "--movement-speed-range":
			if !parse_float_range_flag(&cfg.movement_speed_range, args, &i, value, has_value) do return false
		case "--gap":
			if !parse_int_flag(&cfg.gap, args, &i, value, has_value) do return false
		case "--starting-color":
			if !parse_color_flag(&cfg.starting_color, args, &i, value, has_value) do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-frames":
			if !parse_int_flag(&cfg.final_gradient_frames, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case "--movement-easing":
			if !parse_ease_flag(&cfg.movement_easing, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown pour option: ", name)
			return false
		}
	}
	return true
}

Pour_State :: struct {
	config:      Pour_Config,
	pool:        [dynamic]engine.Char_Id, // all groups, concatenated
	group_spans: [dynamic]engine.Span, // one span per group
	revealed:    [dynamic]engine.Char_Id,
	group_idx:   int, // group currently being poured
	head:        int, // cursor within the current group
	gap:         int,
}

pour_build :: proc(s: ^Pour_State, e: ^engine.Engine) {
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

	grouping: engine.Character_Group
	switch s.config.pour_direction {
	case .Down:
		grouping = .Row_B2T
	case .Up:
		grouping = .Row_T2B
	case .Left:
		grouping = .Column_L2R
	case .Right:
		grouping = .Column_R2L
	}
	query := engine.Character_Query{e.character_sets, e.chars.input_coord[:], e.canvas}
	groups := engine.get_characters_grouped(query, engine.filter_input(), grouping)
	input_coords := e.chars.input_coord[:]
	current_coords := e.chars.current_coord[:]
	input_symbols := e.chars.input_symbol[:]
	visible := e.chars.is_visible[:]

	for gi in 0 ..< engine.group_count(groups) {
		g := engine.group_slice(groups, gi)
		if gi % 2 == 1 do engine.reverse_slice(g) // pour direction alternates
		append(&s.group_spans, engine.Span{start = len(s.pool), len = len(g)})
		for id in g {
			append(&s.pool, id)
			c := input_coords[id]
			start: engine.Coord
			switch s.config.pour_direction {
			case .Down:
				start = engine.coord(c.column, e.canvas.top)
			case .Up:
				start = engine.coord(c.column, e.canvas.bottom)
			case .Left:
				start = engine.coord(e.canvas.right, c.row)
			case .Right:
				start = engine.coord(e.canvas.left, c.row)
			}
			current_coords[id] = start
			speed := rand.float64_range(
				s.config.movement_speed_range.lo,
				s.config.movement_speed_range.hi,
			)
			p := engine.new_path(e, speed, s.config.movement_easing, nil, 0, false)
			engine.path_add_waypoint(&e.paths[p], c)
			engine.activate_path(e, id, p)

			sc := engine.new_scene(e, false, .None, {})
			final_color := engine.gradient_sample(sampler, spectrum[:], c)
			g2 := engine.gradient_make(
				[]engine.Color{s.config.starting_color, final_color},
				s.config.final_gradient_steps[:],
				false,
			)
			engine.scene_add_gradient(
				&e.scenes[sc],
				[]string{input_symbols[id]},
				s.config.final_gradient_frames,
				g2[:],
				nil,
			)
			delete(g2[:])
			engine.activate_scene(e, id, sc)
			visible[id] = false
		}
	}
	engine.groups_delete(&groups)
}

pour_next :: proc(s: ^Pour_State, e: ^engine.Engine) -> bool {
	spans := s.group_spans[:]
	pool := s.pool[:]
	visible := e.chars.is_visible[:]
	if s.group_idx >= len(spans) && len(e.active) == 0 {
		return false
	}
	if s.group_idx < len(spans) {
		cur := spans[s.group_idx]
		if s.gap == 0 {
			for _ in 0 ..< s.config.pour_speed {
				if s.head >= cur.len do break
				next := pool[cur.start + s.head]
				s.head += 1
				visible[next] = true
				append(&s.revealed, next)
				engine.active_insert(e, next)
			}
			if s.head >= cur.len {
				s.group_idx += 1
				s.head = 0
			}
			s.gap = s.config.gap
		} else {
			s.gap -= 1
		}
	}
	engine.update(e)
	engine.frame(e, s.revealed[:])
	return true
}
