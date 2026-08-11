package effects

import engine "../engine"

import "core:fmt"
import "core:math/rand"

Vhs_Noise_Symbols :: [4]string{"#", "*", ".", ":"}

Vhstape_Config :: struct {
	glitch_line_colors:       [dynamic]engine.Color,
	glitch_wave_colors:       [dynamic]engine.Color,
	noise_colors:             [dynamic]engine.Color,
	glitch_line_chance:       f64,
	noise_chance:             f64,
	total_glitch_time:        int,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

vhstape_config_default :: proc() -> Vhstape_Config {
	cfg := Vhstape_Config {
		glitch_line_chance       = 0.05,
		noise_chance             = 0.004,
		total_glitch_time        = 600,
		final_gradient_direction = .Vertical,
	}
	append(
		&cfg.glitch_line_colors,
		..[]engine.Color {
			engine.Color{0xFF, 0xFF, 0xFF},
			engine.Color{0xFF, 0x00, 0x00},
			engine.Color{0x00, 0xFF, 0x00},
			engine.Color{0x00, 0x00, 0xFF},
			engine.Color{0xFF, 0xFF, 0xFF},
		},
	)
	append(&cfg.glitch_wave_colors, ..cfg.glitch_line_colors[:])
	append(
		&cfg.noise_colors,
		..[]engine.Color {
			engine.Color{0x1E, 0x1E, 0x1F},
			engine.Color{0x3C, 0x3B, 0x3D},
			engine.Color{0x6D, 0x6C, 0x70},
			engine.Color{0xA2, 0xA1, 0xA6},
			engine.Color{0xCB, 0xC9, 0xCF},
			engine.Color{0xFF, 0xFF, 0xFF},
		},
	)
	append(
		&cfg.final_gradient_stops,
		..[]engine.Color {
			engine.Color{0xAB, 0x48, 0xFF},
			engine.Color{0xE7, 0xB2, 0xB2},
			engine.Color{0xFF, 0xFE, 0xBD},
		},
	)
	append(&cfg.final_gradient_steps, 12)
	return cfg
}

vhstape_parse :: proc(cfg: ^Vhstape_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--glitch-line-colors":
			if !parse_colors_flag(&cfg.glitch_line_colors, args, &i, value, has_value) do return false
		case "--glitch-wave-colors":
			if !parse_colors_flag(&cfg.glitch_wave_colors, args, &i, value, has_value) do return false
		case "--noise-colors":
			if !parse_colors_flag(&cfg.noise_colors, args, &i, value, has_value) do return false
		case "--glitch-line-chance":
			if !parse_float_flag(&cfg.glitch_line_chance, args, &i, value, has_value) || cfg.glitch_line_chance < 0 || cfg.glitch_line_chance > 1 do return false
		case "--noise-chance":
			if !parse_float_flag(&cfg.noise_chance, args, &i, value, has_value) || cfg.noise_chance < 0 || cfg.noise_chance > 1 do return false
		case "--total-glitch-time":
			if !parse_int_flag(&cfg.total_glitch_time, args, &i, value, has_value) || cfg.total_glitch_time <= 0 do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown vhstape option: ", name)
			return false
		}
	}
	return true
}

Vhstape_Phase :: enum {
	Glitching,
	Noise,
	Redraw,
	Complete,
}

Vhstape_Motion :: enum u8 {
	Idle,
	Glitch,
	Restore,
	Wave,
}
Vhstape_Scene :: enum u8 {
	Idle,
	Forward,
	Backward,
	Base,
	Snow,
	Final_Snow,
	Final_Redraw,
}

Vhstape_Noise_Frame :: struct {
	symbol: u8,
	color:  u16,
}

VHSTAPE_SNOW_FRAMES :: 25
VHSTAPE_FINAL_SNOW_FRAMES :: 30
// An activated path can only span from one 25-column glitch endpoint to the
// opposite endpoint. At its slowest, that is exactly 50 one-cell frames.
VHSTAPE_LANE_COORD_CAPACITY :: 50

Vhstape_State :: struct {
	config:                Vhstape_Config,
	characters:            [dynamic]engine.Char_Id,
	index_by_id:           []int,
	final_colors:          []engine.Color,
	rows:                  engine.Char_Groups,
	row_offsets:           []int,
	row_is_wave:           []u8,
	row_is_glitch:         []u8,
	active_wave_rows:      [dynamic]int,
	active_glitch_rows:    [dynamic]int,
	active_wave_top:       int,
	snow_frames:           []Vhstape_Noise_Frame,
	final_snow_frames:     []Vhstape_Noise_Frame,
	motions:               []Vhstape_Motion,
	motion_coords:         []engine.Coord,
	motion_frame:          []int,
	motion_frame_count:    []int,
	motion_holds:          []int,
	return_steps:          []int,
	scenes:                []Vhstape_Scene,
	scene_ticks:           []int,
	active_characters:     [dynamic]engine.Char_Id,
	active_character_bits: []u8,
	phase:                 Vhstape_Phase,
	tick:                  int,
	redraw_row:            int,
	redrawing:             bool,
	color_handling:        engine.Existing_Color_Handling,
}

vhstape_build :: proc(s: ^Vhstape_State, e: ^engine.Engine) {
	s.color_handling = e.cfg.existing_color_handling
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
	storage_len := len(e.chars)
	s.index_by_id = make([]int, storage_len)
	for i in 0 ..< storage_len do s.index_by_id[i] = -1
	s.final_colors = make([]engine.Color, storage_len)
	input_coords := e.chars.input_coord
	visual_fg := e.chars.visual
	visible := e.chars.is_visible
	for id, i in s.characters {
		s.index_by_id[id] = i
		s.final_colors[id] = engine.gradient_sample(sampler, spectrum[:], input_coords[id])
		if s.color_handling == .Dynamic {
			style := e.chars.input_style[id]
			visual_fg[id].fg = style.fg != nil ? style.fg : engine.Color{0x80, 0x80, 0x80}
			visual_fg[id].bg = style.bg
		} else {
			visual_fg[id].fg = s.final_colors[id]
		}
		visible[id] = true
	}
	s.rows = engine.get_characters_grouped(query, engine.CHAR_FILTER_INPUT, .Row_B2T)
	row_count := len(s.rows.spans)
	s.row_offsets = make([]int, row_count)
	s.row_is_wave = make([]u8, row_count)
	s.row_is_glitch = make([]u8, row_count)
	reserve(&s.active_wave_rows, 3)
	reserve(&s.active_glitch_rows, 3)
	s.active_wave_top = -1

	// Python/Rust draw all snow choices while constructing each line. Keep the
	// fixed sequences compact and indexed by dense character slot.
	s.snow_frames = make([]Vhstape_Noise_Frame, n * VHSTAPE_SNOW_FRAMES)
	s.final_snow_frames = make([]Vhstape_Noise_Frame, n * VHSTAPE_FINAL_SNOW_FRAMES)
	for row in 0 ..< row_count {
		offset := rand.int_range(4, 26)
		if rand.int_max(2) == 0 do offset = -offset
		s.row_offsets[row] = offset
		_ = rand.int_range(1, 51) // initial path hold; runtime activation replaces it
		for id in engine.group_members(s.rows, row) {
			i := s.index_by_id[id]
			for frame in 0 ..< VHSTAPE_SNOW_FRAMES {
				s.snow_frames[i * VHSTAPE_SNOW_FRAMES + frame] = {
					u8(rand.int_max(len(Vhs_Noise_Symbols))),
					u16(rand.int_max(len(s.config.noise_colors))),
				}
			}
			for frame in 0 ..< VHSTAPE_FINAL_SNOW_FRAMES {
				s.final_snow_frames[i * VHSTAPE_FINAL_SNOW_FRAMES + frame] = {
					u8(rand.int_max(len(Vhs_Noise_Symbols))),
					u16(rand.int_max(len(s.config.noise_colors))),
				}
			}
		}
	}

	s.motions = make([]Vhstape_Motion, storage_len)
	s.motion_coords = make([]engine.Coord, storage_len * VHSTAPE_LANE_COORD_CAPACITY)
	s.motion_frame = make([]int, storage_len)
	s.motion_frame_count = make([]int, storage_len)
	s.motion_holds = make([]int, storage_len)
	s.return_steps = make([]int, storage_len)
	s.scenes = make([]Vhstape_Scene, storage_len)
	s.scene_ticks = make([]int, storage_len)
	s.active_character_bits = make([]u8, storage_len)
	reserve(&s.active_characters, n)
	s.redraw_row = row_count - 1
}

vhstape_set_stable_visual :: proc(
	s: ^Vhstape_State,
	chars: ^engine.Character_Storage,
	id: engine.Char_Id,
) {
	chars.visual[id].symbol = chars.input_symbol[id]
	if s.color_handling == .Dynamic {
		style := chars.input_style[id]
		chars.visual[id].fg = style.fg != nil ? style.fg : engine.Color{0x80, 0x80, 0x80}
		chars.visual[id].bg = style.bg
	} else {
		chars.visual[id].fg = s.final_colors[id]
		chars.visual[id].bg = nil
	}
}

vhstape_set_final_visual :: proc(
	s: ^Vhstape_State,
	chars: ^engine.Character_Storage,
	id: engine.Char_Id,
) {
	chars.visual[id].symbol = chars.input_symbol[id]
	if s.color_handling == .Dynamic {
		engine.dynamic_apply_input_colors(&chars.visual[id], chars.input_style[id])
	} else {
		chars.visual[id].fg = s.final_colors[id]
		chars.visual[id].bg = nil
	}
}


vhstape_activate_character :: proc(s: ^Vhstape_State, id: engine.Char_Id) {
	if s.active_character_bits[id] != 0 do return
	s.active_character_bits[id] = 1
	append(&s.active_characters, id)
}

vhstape_noise_visual :: proc(
	s: ^Vhstape_State,
	frames: []Vhstape_Noise_Frame,
	frame_count: int,
	id: engine.Char_Id,
	frame: int,
) -> engine.Visual {
	i := s.index_by_id[id]
	choice := frames[i * frame_count + frame]
	symbols := Vhs_Noise_Symbols
	return {symbol = symbols[choice.symbol], fg = s.config.noise_colors[choice.color]}
}

vhstape_start_scene :: proc(
	s: ^Vhstape_State,
	chars: ^engine.Character_Storage,
	id: engine.Char_Id,
	scene: Vhstape_Scene,
) {
	s.scenes[id] = scene
	symbol := chars.input_symbol[id]
	switch scene {
	case .Forward:
		chars.visual[id] = {
			symbol = symbol,
			fg     = s.config.glitch_line_colors[0],
		}
	case .Backward:
		chars.visual[id] = {
			symbol = symbol,
			fg     = s.config.glitch_line_colors[len(s.config.glitch_line_colors) - 1],
		}
	case .Base:
		s.scene_ticks[id] = 0
		vhstape_set_stable_visual(s, chars, id)
	case .Snow:
		step := s.scene_ticks[id]
		if step < VHSTAPE_SNOW_FRAMES * 2 {
			chars.visual[id] = vhstape_noise_visual(
				s,
				s.snow_frames[:],
				VHSTAPE_SNOW_FRAMES,
				id,
				step / 2,
			)
		} else {
			vhstape_set_stable_visual(s, chars, id)
		}
	case .Final_Snow:
		s.scene_ticks[id] = 0
		chars.visual[id] = vhstape_noise_visual(
			s,
			s.final_snow_frames[:],
			VHSTAPE_FINAL_SNOW_FRAMES,
			id,
			0,
		)
	case .Final_Redraw:
		s.scene_ticks[id] = 0
		chars.visual[id] = {
			symbol = "█",
			fg     = engine.Color{0xFF, 0xFF, 0xFF},
		}
	case .Idle:
	}
}

vhstape_start_motion :: proc(
	s: ^Vhstape_State,
	chars: ^engine.Character_Storage,
	id: engine.Char_Id,
	kind: Vhstape_Motion,
	target: engine.Coord,
	max_steps, hold: int,
) {
	s.motions[id] = kind
	s.motion_frame[id] = 0
	s.motion_frame_count[id] = max_steps
	s.motion_holds[id] = hold
	assert(max_steps <= VHSTAPE_LANE_COORD_CAPACITY)
	base := int(id) * VHSTAPE_LANE_COORD_CAPACITY
	for frame in 1 ..= max_steps {
		s.motion_coords[base + frame - 1] = engine.coord_on_line(
			chars.current_coord[id],
			target,
			f64(frame) / f64(max_steps),
		)
	}
	vhstape_start_scene(s, chars, id, kind == .Restore ? .Backward : .Forward)
	vhstape_activate_character(s, id)
}

vhstape_steps :: proc(origin, target: engine.Coord, denominator: int) -> int {
	return engine.round_half_even(
		engine.line_length(origin, target, true) * f64(denominator) / 40.0,
	)
}

vhstape_start_restore :: proc(
	s: ^Vhstape_State,
	chars: ^engine.Character_Storage,
	id: engine.Char_Id,
	steps: int,
) {
	vhstape_start_motion(s, chars, id, .Restore, chars.input_coord[id], steps, 0)
}

vhstape_restore_row :: proc(s: ^Vhstape_State, chars: ^engine.Character_Storage, row: int) {
	for id in engine.group_members(s.rows, row) {
		steps := vhstape_steps(
			chars.current_coord[id],
			chars.input_coord[id],
			rand.int_range(20, 41),
		)
		vhstape_start_restore(s, chars, id, steps)
	}
}

vhstape_start_glitch_row :: proc(
	s: ^Vhstape_State,
	chars: ^engine.Character_Storage,
	row, hold: int,
) {
	for id in engine.group_members(s.rows, row) {
		p := chars.input_coord[id]
		target := engine.coord(p.column + s.row_offsets[row], p.row)
		out_steps := vhstape_steps(chars.current_coord[id], target, rand.int_range(20, 41))
		s.return_steps[id] = vhstape_steps(target, p, rand.int_range(20, 41))
		vhstape_start_motion(s, chars, id, .Glitch, target, out_steps, hold)
	}
}

vhstape_start_wave_row :: proc(
	s: ^Vhstape_State,
	chars: ^engine.Character_Storage,
	row, offset: int,
) {
	for id in engine.group_members(s.rows, row) {
		p := chars.input_coord[id]
		target := engine.coord(p.column + offset, p.row)
		vhstape_start_motion(
			s,
			chars,
			id,
			.Wave,
			target,
			vhstape_steps(chars.current_coord[id], target, 20),
			0,
		)
	}
}

vhstape_row_motion_complete :: proc(s: ^Vhstape_State, row: int) -> bool {
	for id in engine.group_members(s.rows, row) {
		if s.motions[id] != .Idle do return false
	}
	return true
}

vhstape_rows_complete :: proc(s: ^Vhstape_State, rows: []int) -> bool {
	for row in rows {
		if !vhstape_row_motion_complete(s, row) do return false
	}
	return true
}

vhstape_contains_row :: proc(rows: []int, row: int) -> bool {
	for candidate in rows {
		if candidate == row do return true
	}
	return false
}

vhstape_glitch_wave :: proc(
	s: ^Vhstape_State,
	chars: ^engine.Character_Storage,
	canvas: engine.Canvas,
) {
	if s.active_wave_top < 0 {
		if canvas.text_height < 3 do return
		lower := max(3, engine.round_half_even(f64(canvas.text_height) * 0.5))
		s.active_wave_top = canvas.text_bottom + rand.int_range(lower, canvas.text_height + 1)
	} else if len(s.active_wave_rows) > 0 {
		if rand.float64() < 0.3 do s.active_wave_top += rand.float64() < 0.3 ? 1 : -1
		s.active_wave_top = clamp(s.active_wave_top, 2, canvas.text_top)
	}

	new_rows: [3]int
	new_count := 0
	for line := s.active_wave_top - 2; line <= s.active_wave_top; line += 1 {
		row := line - (canvas.text_bottom - 1)
		if row >= 0 && row < len(s.rows.spans) {
			new_rows[new_count] = row
			new_count += 1
		}
	}
	for row in s.active_wave_rows {
		if !vhstape_contains_row(new_rows[:new_count], row) {
			vhstape_restore_row(s, chars, row)
			s.row_is_wave[row] = 0
		}
	}
	clear(&s.active_wave_rows)
	for row in new_rows[:new_count] {
		append(&s.active_wave_rows, row)
		s.row_is_wave[row] = 1
	}
	if s.active_wave_top < canvas.text_bottom + 2 {
		for row in s.active_wave_rows {
			vhstape_restore_row(s, chars, row)
			s.row_is_wave[row] = 0
		}
		clear(&s.active_wave_rows)
		s.active_wave_top = -1
		return
	}
	offsets := [3]int{8, 14, 8}
	for row, i in s.active_wave_rows do vhstape_start_wave_row(s, chars, row, offsets[i])
}

vhstape_motion_step :: proc(
	s: ^Vhstape_State,
	chars: ^engine.Character_Storage,
	id: engine.Char_Id,
) {
	kind := s.motions[id]
	if kind == .Idle do return
	frame, frame_count := s.motion_frame[id], s.motion_frame_count[id]
	if frame < frame_count {
		chars.current_coord[id] = s.motion_coords[int(id) * VHSTAPE_LANE_COORD_CAPACITY + frame]
		frame += 1
		s.motion_frame[id] = frame
	}
	if frame != frame_count do return
	if s.motion_holds[id] > 0 {
		s.motion_holds[id] -= 1
		return
	}
	s.motions[id] = .Idle
	if kind == .Glitch do vhstape_start_restore(s, chars, id, s.return_steps[id])
}

vhstape_synced_color :: proc(
	palette: []engine.Color,
	step, max_steps: int,
	reverse: bool,
) -> engine.Color {
	i := clamp(
		engine.round_half_even(f64(len(palette) - 1) * f64(max(step, 1)) / f64(max(max_steps, 1))),
		0,
		len(palette) - 1,
	)
	if reverse do i = len(palette) - 1 - i
	return palette[i]
}

vhstape_scene_step :: proc(
	s: ^Vhstape_State,
	chars: ^engine.Character_Storage,
	id: engine.Char_Id,
) {
	scene := s.scenes[id]
	if scene == .Idle do return
	symbol := chars.input_symbol[id]
	switch scene {
	case .Forward:
		if s.motions[id] == .Idle {
			chars.visual[id] = {
				symbol = symbol,
				fg     = s.config.glitch_line_colors[len(s.config.glitch_line_colors) - 1],
			}
			s.scenes[id] = .Idle
		} else {
			chars.visual[id] = {
				symbol = symbol,
				fg     = vhstape_synced_color(
					s.config.glitch_line_colors[:],
					s.motion_frame[id],
					s.motion_frame_count[id],
					false,
				),
			}
		}
	case .Backward:
		if s.motions[id] == .Idle {
			vhstape_start_scene(s, chars, id, .Base)
		} else {
			chars.visual[id] = {
				symbol = symbol,
				fg     = vhstape_synced_color(
					s.config.glitch_line_colors[:],
					s.motion_frame[id],
					s.motion_frame_count[id],
					true,
				),
			}
		}
	case .Base:
		vhstape_set_stable_visual(s, chars, id)
		s.scenes[id] = .Idle
	case .Snow:
		step := s.scene_ticks[id]
		if step < VHSTAPE_SNOW_FRAMES * 2 {
			chars.visual[id] = vhstape_noise_visual(
				s,
				s.snow_frames[:],
				VHSTAPE_SNOW_FRAMES,
				id,
				step / 2,
			)
		} else {
			vhstape_set_stable_visual(s, chars, id)
		}
		s.scene_ticks[id] += 1
		if s.scene_ticks[id] == VHSTAPE_SNOW_FRAMES * 2 + 1 {
			s.scene_ticks[id] = 0
			s.scenes[id] = .Idle
		}
	case .Final_Snow:
		step := s.scene_ticks[id]
		chars.visual[id] = vhstape_noise_visual(
			s,
			s.final_snow_frames[:],
			VHSTAPE_FINAL_SNOW_FRAMES,
			id,
			step / 2,
		)
		s.scene_ticks[id] += 1
		if s.scene_ticks[id] == VHSTAPE_FINAL_SNOW_FRAMES * 2 do s.scenes[id] = .Idle
	case .Final_Redraw:
		if s.scene_ticks[id] < 6 {
			chars.visual[id] = {
				symbol = "█",
				fg     = engine.Color{0xFF, 0xFF, 0xFF},
			}
		} else {
			vhstape_set_final_visual(s, chars, id)
		}
		s.scene_ticks[id] += 1
		if s.scene_ticks[id] == 7 do s.scenes[id] = .Idle
	case .Idle:
	}
}

vhstape_update_active :: proc(s: ^Vhstape_State, chars: ^engine.Character_Storage) {
	write := 0
	for id in s.active_characters {
		vhstape_motion_step(s, chars, id)
		vhstape_scene_step(s, chars, id)
		if s.motions[id] != .Idle || s.scenes[id] != .Idle {
			s.active_characters[write] = id
			write += 1
		} else {
			s.active_character_bits[id] = 0
		}
	}
	resize(&s.active_characters, write)
}

vhstape_start_snow :: proc(s: ^Vhstape_State, chars: ^engine.Character_Storage, final: bool) {
	for id in s.characters {
		vhstape_start_scene(s, chars, id, final ? .Final_Snow : .Snow)
		vhstape_activate_character(s, id)
	}
}

vhstape_start_redraw_row :: proc(s: ^Vhstape_State, chars: ^engine.Character_Storage, row: int) {
	for id in engine.group_members(s.rows, row) {
		vhstape_start_scene(s, chars, id, .Final_Redraw)
		vhstape_activate_character(s, id)
	}
}

vhstape_next :: proc(s: ^Vhstape_State, e: ^engine.Engine) -> ([]engine.Char_Id, bool) {
	chars := &e.chars
	if s.phase == .Complete && len(s.active_characters) == 0 do return nil, false
	switch s.phase {
	case .Glitching:
		if len(s.active_wave_rows) == 0 || vhstape_rows_complete(s, s.active_wave_rows[:]) {
			vhstape_glitch_wave(s, chars, e.canvas)
		}
		write := 0
		for row in s.active_glitch_rows {
			if vhstape_row_motion_complete(s, row) {
				s.row_is_glitch[row] = 0
			} else {
				s.active_glitch_rows[write] = row
				write += 1
			}
		}
		resize(&s.active_glitch_rows, write)
		if rand.float64() < s.config.glitch_line_chance && len(s.active_glitch_rows) < 3 {
			row := rand.int_max(len(s.rows.spans))
			if s.row_is_wave[row] == 0 && s.row_is_glitch[row] == 0 {
				s.row_is_glitch[row] = 1
				append(&s.active_glitch_rows, row)
				vhstape_start_glitch_row(s, chars, row, rand.int_range(20, 76))
			}
		}
		if rand.float64() < s.config.noise_chance do vhstape_start_snow(s, chars, false)
		s.tick += 1
		if s.tick >= s.config.total_glitch_time {
			for row in s.active_wave_rows do vhstape_restore_row(s, chars, row)
			for row in s.active_glitch_rows do vhstape_restore_row(s, chars, row)
			s.phase = .Noise
		}
	case .Noise:
		if len(s.active_characters) == 0 {
			vhstape_start_snow(s, chars, true)
			s.phase = .Redraw
		}
	case .Redraw:
		if s.redrawing || len(s.active_characters) == 0 {
			s.redrawing = true
			if s.redraw_row >= 0 {
				vhstape_start_redraw_row(s, chars, s.redraw_row)
				s.redraw_row -= 1
			} else {
				s.phase = .Complete
			}
		}
	case .Complete:
	}
	vhstape_update_active(s, chars)
	return s.characters[:], true
}
