package effects

import engine "../engine"

import "core:fmt"

@(private = "file", rodata)
Vhs_Noise_Symbols := [4]rune{'#', '*', '.', ':'}

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

Vhstape_State :: struct {
	config:                Vhstape_Config,
	characters:            [dynamic]engine.Particle_Id,
	index_by_id:           []int,
	stable_codes:          []engine.Appearance_Id,
	final_codes:           []engine.Appearance_Id,
	glitch_line_codes:     []engine.Appearance_Id,
	white_code:            engine.Appearance_Id,
	rows:                  engine.Particle_Groups,
	row_offsets:           []int,
	row_is_wave:           []u8,
	row_is_glitch:         []u8,
	active_wave_rows:      [dynamic]int,
	active_glitch_rows:    [dynamic]int,
	active_wave_top:       int,
	noise_codes:           []engine.Appearance_Id, // one prepared appearance per noise color
	snow_frames:           []Vhstape_Noise_Frame, // frame-major: [frame * n + i]
	final_snow_frames:     []Vhstape_Noise_Frame, // frame-major: [frame * n + i]
	motions:               []Vhstape_Motion,
	motion_origins:        []engine.Coord,
	motion_targets:        []engine.Coord,
	motion_frame:          []int,
	motion_frame_count:    []int,
	motion_holds:          []int,
	return_steps:          []int,
	scenes:                []Vhstape_Scene,
	scene_ticks:           []int,
	active_characters:     [dynamic]engine.Particle_Id,
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
		context.temp_allocator,
	)
	defer delete(spectrum)
	sampler := engine.gradient_sampler(
		e.canvas.text_bottom,
		e.canvas.text_top,
		e.canvas.text_left,
		e.canvas.text_right,
		s.config.final_gradient_direction,
	)
	query := engine.Particle_Query {
		e.particle_sets,
		e.particles.initial_coord[:len(e.particles)],
		e.canvas,
	}
	s.characters = engine.get_particles(
		query,
		engine.PARTICLE_FILTER_INPUT,
		.Top_Bottom_Left_Right,
	)
	n := len(s.characters)
	storage_len := len(e.particles)
	s.index_by_id = make([]int, storage_len)
	for i in 0 ..< storage_len do s.index_by_id[i] = -1
	s.stable_codes = make([]engine.Appearance_Id, storage_len)
	s.final_codes = make([]engine.Appearance_Id, storage_len)
	s.white_code = engine.prepare_appearance(e, {colors = {fg = engine.Color{0xFF, 0xFF, 0xFF}}})
	s.glitch_line_codes = make([]engine.Appearance_Id, len(s.config.glitch_line_colors))
	for gc, gi in s.config.glitch_line_colors {
		s.glitch_line_codes[gi] = engine.prepare_appearance(e, {colors = {fg = gc}})
	}

	if n > 0 {
		stable_styles := make([]engine.Appearance, n, context.temp_allocator)
		final_styles := make([]engine.Appearance, n, context.temp_allocator)
		defer delete(stable_styles, context.temp_allocator)
		defer delete(final_styles, context.temp_allocator)
		initial_coords := e.particles.initial_coord
		for id, i in s.characters {
			s.index_by_id[id] = i
			if s.color_handling == .Dynamic {
				style := engine.get_initial_appearance(e, id)
				stable_styles[i] = {
					colors = {
						fg = style.colors.fg != nil ? style.colors.fg : engine.Color{0x80, 0x80, 0x80},
						bg = style.colors.bg,
					},
				}
				final_styles[i] = {colors = style.colors}
			} else {
				fc := engine.gradient_sample(sampler, spectrum[:], initial_coords[id])
				stable_styles[i] = {colors = {fg = fc}}
				final_styles[i] = {colors = {fg = fc}}
			}
		}
		unique_stable, stable_idx := engine.group_values(stable_styles)
		defer delete(unique_stable)
		defer delete(stable_idx)
		u_stable_codes := make([]engine.Appearance_Id, len(unique_stable), context.temp_allocator)
		defer delete(u_stable_codes, context.temp_allocator)
		for st, idx in unique_stable do u_stable_codes[idx] = engine.prepare_appearance(e, st)

		if s.color_handling == .Dynamic {
			unique_final, final_idx := engine.group_values(final_styles)
			defer delete(unique_final)
			defer delete(final_idx)
			u_final_codes := make([]engine.Appearance_Id, len(unique_final), context.temp_allocator)
			defer delete(u_final_codes, context.temp_allocator)
			for st, idx in unique_final do u_final_codes[idx] = engine.prepare_appearance(e, st)
			for id, i in s.characters {
				sc := u_stable_codes[stable_idx[i]]
				s.stable_codes[id] = sc
				s.final_codes[id] = u_final_codes[final_idx[i]]
				engine.set_appearance(e, id, sc)
				e.particles.flags[id] += {.Visible}
			}
		} else {
			for id, i in s.characters {
				sc := u_stable_codes[stable_idx[i]]
				s.stable_codes[id] = sc
				s.final_codes[id] = sc
				engine.set_appearance(e, id, sc)
				e.particles.flags[id] += {.Visible}
			}
		}
	}

	s.rows = engine.get_particles_grouped(query, engine.PARTICLE_FILTER_INPUT, .Row_B2T)
	row_count := len(s.rows.spans)
	s.row_offsets = make([]int, row_count)
	s.row_is_wave = make([]u8, row_count)
	s.row_is_glitch = make([]u8, row_count)
	reserve(&s.active_wave_rows, 3)
	reserve(&s.active_glitch_rows, 3)
	s.active_wave_top = -1

	// Python/Rust draw all snow choices while constructing each line. Keep the
	// fixed sequences compact and frame-major so full-screen snow scans contiguously.
	s.noise_codes = make([]engine.Appearance_Id, len(s.config.noise_colors))
	for color, i in s.config.noise_colors {
		s.noise_codes[i] = engine.prepare_appearance(e, engine.Appearance{colors = {fg = color}})
	}
	s.snow_frames = make([]Vhstape_Noise_Frame, n * VHSTAPE_SNOW_FRAMES)
	s.final_snow_frames = make([]Vhstape_Noise_Frame, n * VHSTAPE_FINAL_SNOW_FRAMES)
	for row in 0 ..< row_count {
		offset := engine.random_range(4, 26)
		if engine.random_below(2) == 0 do offset = -offset
		s.row_offsets[row] = offset
		_ = engine.random_range(1, 51) // initial path hold; runtime activation replaces it
		for id in engine.group_members(s.rows, row) {
			i := s.index_by_id[id]
			for frame in 0 ..< VHSTAPE_SNOW_FRAMES {
				s.snow_frames[frame * n + i] = {
					u8(engine.random_below(len(Vhs_Noise_Symbols))),
					u16(engine.random_below(len(s.config.noise_colors))),
				}
			}
			for frame in 0 ..< VHSTAPE_FINAL_SNOW_FRAMES {
				s.final_snow_frames[frame * n + i] = {
					u8(engine.random_below(len(Vhs_Noise_Symbols))),
					u16(engine.random_below(len(s.config.noise_colors))),
				}
			}
		}
	}

	s.motions = make([]Vhstape_Motion, storage_len)
	s.motion_origins = make([]engine.Coord, storage_len)
	s.motion_targets = make([]engine.Coord, storage_len)
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

vhstape_set_stable_appearance :: #force_inline proc(
	s: ^Vhstape_State,
	e: ^engine.Engine,
	id: engine.Particle_Id,
) #no_bounds_check {
	engine.set_symbol(e, id, e.particles.initial_symbol[id])
	engine.set_appearance(e, id, s.stable_codes[id])
}

vhstape_set_final_appearance :: #force_inline proc(
	s: ^Vhstape_State,
	e: ^engine.Engine,
	id: engine.Particle_Id,
) #no_bounds_check {
	engine.set_symbol(e, id, e.particles.initial_symbol[id])
	engine.set_appearance(e, id, s.final_codes[id])
}

vhstape_activate_character :: #force_inline proc(s: ^Vhstape_State, id: engine.Particle_Id) #no_bounds_check {
	if s.active_character_bits[id] != 0 do return
	s.active_character_bits[id] = 1
	append(&s.active_characters, id)
}

vhstape_noise_appearance :: #force_inline proc(
	s: ^Vhstape_State,
	frames: []Vhstape_Noise_Frame,
	id: engine.Particle_Id,
	frame: int,
) -> (
	rune,
	engine.Appearance_Id,
) #no_bounds_check {
	i := s.index_by_id[id]
	choice := frames[frame * len(s.characters) + i]
	symbols := Vhs_Noise_Symbols
	return symbols[choice.symbol], s.noise_codes[choice.color]
}

vhstape_start_scene :: proc(
	s: ^Vhstape_State,
	e: ^engine.Engine,
	id: engine.Particle_Id,
	scene: Vhstape_Scene,
) #no_bounds_check {
	s.scenes[id] = scene
	symbol := e.particles.initial_symbol[id]
	switch scene {
	case .Forward:
		engine.set_symbol(e, id, symbol)
		engine.set_appearance(e, id, s.glitch_line_codes[0])
	case .Backward:
		engine.set_symbol(e, id, symbol)
		engine.set_appearance(e, id, s.glitch_line_codes[len(s.glitch_line_codes) - 1])
	case .Base:
		s.scene_ticks[id] = 0
		vhstape_set_stable_appearance(s, e, id)
	case .Snow:
		step := s.scene_ticks[id]
		if step < VHSTAPE_SNOW_FRAMES * 2 {
			sym, appearance := vhstape_noise_appearance(
				s,
				s.snow_frames[:],
				id,
				step / 2,
			)
			engine.set_symbol(e, id, sym)
			engine.set_appearance(e, id, appearance)
		} else {
			vhstape_set_stable_appearance(s, e, id)
		}
	case .Final_Snow:
		s.scene_ticks[id] = 0
		sym, appearance := vhstape_noise_appearance(
			s,
			s.final_snow_frames[:],
			id,
			0,
		)
		engine.set_symbol(e, id, sym)
		engine.set_appearance(e, id, appearance)
	case .Final_Redraw:
		s.scene_ticks[id] = 0
		engine.set_symbol(e, id, '█')
		engine.set_appearance(e, id, s.white_code)
	case .Idle:
	}
}

vhstape_start_motion :: proc(
	s: ^Vhstape_State,
	e: ^engine.Engine,
	id: engine.Particle_Id,
	kind: Vhstape_Motion,
	target: engine.Coord,
	max_steps, hold: int,
) #no_bounds_check {
	s.motions[id] = kind
	s.motion_frame[id] = 0
	s.motion_frame_count[id] = max_steps
	s.motion_holds[id] = hold
	s.motion_origins[id] = e.particles.current_coord[id]
	s.motion_targets[id] = target
	vhstape_start_scene(s, e, id, kind == .Restore ? .Backward : .Forward)
	vhstape_activate_character(s, id)
}

vhstape_steps :: #force_inline proc(origin, target: engine.Coord, denominator: int) -> int {
	return engine.round_to_int(engine.line_length(origin, target, true) * f64(denominator) / 40.0)
}

vhstape_start_restore :: proc(
	s: ^Vhstape_State,
	e: ^engine.Engine,
	id: engine.Particle_Id,
	steps: int,
) #no_bounds_check {
	vhstape_start_motion(s, e, id, .Restore, e.particles.initial_coord[id], steps, 0)
}

vhstape_restore_row :: proc(s: ^Vhstape_State, e: ^engine.Engine, row: int) #no_bounds_check {
	for id in engine.group_members(s.rows, row) {
		steps := vhstape_steps(
			e.particles.current_coord[id],
			e.particles.initial_coord[id],
			engine.random_range(20, 41),
		)
		vhstape_start_restore(s, e, id, steps)
	}
}

vhstape_start_glitch_row :: proc(s: ^Vhstape_State, e: ^engine.Engine, row, hold: int) #no_bounds_check {
	for id in engine.group_members(s.rows, row) {
		p := e.particles.initial_coord[id]
		target := engine.coord(p.column + s.row_offsets[row], p.row)
		out_steps := vhstape_steps(e.particles.current_coord[id], target, engine.random_range(20, 41))
		s.return_steps[id] = vhstape_steps(target, p, engine.random_range(20, 41))
		vhstape_start_motion(s, e, id, .Glitch, target, out_steps, hold)
	}
}

vhstape_start_wave_row :: proc(s: ^Vhstape_State, e: ^engine.Engine, row, offset: int) #no_bounds_check {
	for id in engine.group_members(s.rows, row) {
		p := e.particles.initial_coord[id]
		target := engine.coord(p.column + offset, p.row)
		vhstape_start_motion(
			s,
			e,
			id,
			.Wave,
			target,
			vhstape_steps(e.particles.current_coord[id], target, 20),
			0,
		)
	}
}

vhstape_row_motion_complete :: proc(s: ^Vhstape_State, row: int) -> bool #no_bounds_check {
	for id in engine.group_members(s.rows, row) {
		if s.motions[id] != .Idle do return false
	}
	return true
}

vhstape_rows_complete :: proc(s: ^Vhstape_State, rows: []int) -> bool #no_bounds_check {
	for row in rows {
		if !vhstape_row_motion_complete(s, row) do return false
	}
	return true
}

vhstape_contains_row :: proc(rows: []int, row: int) -> bool #no_bounds_check {
	for candidate in rows {
		if candidate == row do return true
	}
	return false
}

vhstape_glitch_wave :: proc(s: ^Vhstape_State, e: ^engine.Engine, canvas: engine.Canvas) #no_bounds_check {
	if s.active_wave_top < 0 {
		if canvas.text_height < 3 do return
		lower := max(3, engine.round_to_int(f64(canvas.text_height) * 0.5))
		s.active_wave_top = canvas.text_bottom + engine.random_range(lower, canvas.text_height + 1)
	} else if len(s.active_wave_rows) > 0 {
		if engine.random_float() < 0.3 do s.active_wave_top += engine.random_float() < 0.3 ? 1 : -1
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
			vhstape_restore_row(s, e, row)
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
			vhstape_restore_row(s, e, row)
			s.row_is_wave[row] = 0
		}
		clear(&s.active_wave_rows)
		s.active_wave_top = -1
		return
	}
	offsets := [3]int{8, 14, 8}
	for row, i in s.active_wave_rows do vhstape_start_wave_row(s, e, row, offsets[i])
}

vhstape_motion_step :: proc(s: ^Vhstape_State, e: ^engine.Engine, id: engine.Particle_Id) #no_bounds_check {
	kind := s.motions[id]
	if kind == .Idle do return
	frame, frame_count := s.motion_frame[id], s.motion_frame_count[id]
	if frame < frame_count {
		t := f64(frame + 1) / f64(frame_count)
		engine.set_position(e, id, engine.tween(s.motion_origins[id], s.motion_targets[id], t))
		frame += 1
		s.motion_frame[id] = frame
	}
	if frame != frame_count do return
	if s.motion_holds[id] > 0 {
		s.motion_holds[id] -= 1
		return
	}
	s.motions[id] = .Idle
	if kind == .Glitch do vhstape_start_restore(s, e, id, s.return_steps[id])
}

vhstape_synced_code :: #force_inline proc(
	codes: []engine.Appearance_Id,
	step, max_steps: int,
	reverse: bool,
) -> engine.Appearance_Id #no_bounds_check {
	i := clamp(
		engine.round_to_int(f64(len(codes) - 1) * f64(max(step, 1)) / f64(max(max_steps, 1))),
		0,
		len(codes) - 1,
	)
	if reverse do i = len(codes) - 1 - i
	return codes[i]
}

vhstape_scene_step :: proc(s: ^Vhstape_State, e: ^engine.Engine, id: engine.Particle_Id) #no_bounds_check {
	scene := s.scenes[id]
	if scene == .Idle do return
	symbol := e.particles.initial_symbol[id]
	switch scene {
	case .Forward:
		if s.motions[id] == .Idle {
			engine.set_symbol(e, id, symbol)
			engine.set_appearance(e, id, s.glitch_line_codes[len(s.glitch_line_codes) - 1])
			s.scenes[id] = .Idle
		} else {
			engine.set_symbol(e, id, symbol)
			engine.set_appearance(
				e,
				id,
				vhstape_synced_code(
					s.glitch_line_codes,
					s.motion_frame[id],
					s.motion_frame_count[id],
					false,
				),
			)
		}
	case .Backward:
		if s.motions[id] == .Idle {
			vhstape_start_scene(s, e, id, .Base)
		} else {
			engine.set_symbol(e, id, symbol)
			engine.set_appearance(
				e,
				id,
				vhstape_synced_code(
					s.glitch_line_codes,
					s.motion_frame[id],
					s.motion_frame_count[id],
					true,
				),
			)
		}
	case .Base:
		vhstape_set_stable_appearance(s, e, id)
		s.scenes[id] = .Idle
	case .Snow:
		step := s.scene_ticks[id]
		if step < VHSTAPE_SNOW_FRAMES * 2 {
			if step % 2 == 0 {
				sym, appearance := vhstape_noise_appearance(
					s,
					s.snow_frames[:],
					id,
					step / 2,
				)
				engine.set_symbol(e, id, sym)
				engine.set_appearance(e, id, appearance)
			}
		} else {
			vhstape_set_stable_appearance(s, e, id)
		}
		s.scene_ticks[id] += 1
		if s.scene_ticks[id] == VHSTAPE_SNOW_FRAMES * 2 + 1 {
			s.scene_ticks[id] = 0
			s.scenes[id] = .Idle
		}
	case .Final_Snow:
		step := s.scene_ticks[id]
		if step % 2 == 0 {
			sym, appearance := vhstape_noise_appearance(
				s,
				s.final_snow_frames[:],
				id,
				step / 2,
			)
			engine.set_symbol(e, id, sym)
			engine.set_appearance(e, id, appearance)
		}
		s.scene_ticks[id] += 1
		if s.scene_ticks[id] == VHSTAPE_FINAL_SNOW_FRAMES * 2 do s.scenes[id] = .Idle
	case .Final_Redraw:
		if s.scene_ticks[id] < 6 {
			if s.scene_ticks[id] == 0 {
				engine.set_symbol(e, id, '█')
				engine.set_appearance(e, id, s.white_code)
			}
		} else {
			vhstape_set_final_appearance(s, e, id)
		}
		s.scene_ticks[id] += 1
		if s.scene_ticks[id] == 7 do s.scenes[id] = .Idle
	case .Idle:
	}
}

vhstape_update_active :: proc(s: ^Vhstape_State, e: ^engine.Engine) #no_bounds_check {
	write := 0
	for id in s.active_characters {
		vhstape_motion_step(s, e, id)
		vhstape_scene_step(s, e, id)
		if s.motions[id] != .Idle || s.scenes[id] != .Idle {
			s.active_characters[write] = id
			write += 1
		} else {
			s.active_character_bits[id] = 0
		}
	}
	resize(&s.active_characters, write)
}

vhstape_start_snow :: proc(s: ^Vhstape_State, e: ^engine.Engine, final: bool) #no_bounds_check {
	for id in s.characters {
		vhstape_start_scene(s, e, id, final ? .Final_Snow : .Snow)
		vhstape_activate_character(s, id)
	}
}

vhstape_start_redraw_row :: proc(s: ^Vhstape_State, e: ^engine.Engine, row: int) #no_bounds_check {
	for id in engine.group_members(s.rows, row) {
		vhstape_start_scene(s, e, id, .Final_Redraw)
		vhstape_activate_character(s, id)
	}
}

vhstape_next :: proc(s: ^Vhstape_State, e: ^engine.Engine) -> bool #no_bounds_check {
	if s.phase == .Complete && len(s.active_characters) == 0 do return false
	switch s.phase {
	case .Glitching:
		if len(s.active_wave_rows) == 0 || vhstape_rows_complete(s, s.active_wave_rows[:]) {
			vhstape_glitch_wave(s, e, e.canvas)
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
		if engine.random_float() < s.config.glitch_line_chance && len(s.active_glitch_rows) < 3 {
			row := engine.random_below(len(s.rows.spans))
			if s.row_is_wave[row] == 0 && s.row_is_glitch[row] == 0 {
				s.row_is_glitch[row] = 1
				append(&s.active_glitch_rows, row)
				vhstape_start_glitch_row(s, e, row, engine.random_range(20, 76))
			}
		}
		if engine.random_float() < s.config.noise_chance do vhstape_start_snow(s, e, false)
		s.tick += 1
		if s.tick >= s.config.total_glitch_time {
			for row in s.active_wave_rows do vhstape_restore_row(s, e, row)
			for row in s.active_glitch_rows do vhstape_restore_row(s, e, row)
			s.phase = .Noise
		}
	case .Noise:
		if len(s.active_characters) == 0 {
			vhstape_start_snow(s, e, true)
			s.phase = .Redraw
		}
	case .Redraw:
		if s.redrawing || len(s.active_characters) == 0 {
			s.redrawing = true
			if s.redraw_row >= 0 {
				vhstape_start_redraw_row(s, e, s.redraw_row)
				s.redraw_row -= 1
			} else {
				s.phase = .Complete
			}
		}
	case .Complete:
	}
	vhstape_update_active(s, e)
	return true
}
