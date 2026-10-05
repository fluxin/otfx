package effects

import "../engine"
import "core:math/ease"

import "core:fmt"

// sweep — a gray shimmer sweeps across the whole canvas, then a colored sweep
// lands the final gradient.

Sweep_Config :: struct {
	sweep_symbols:            [dynamic]rune,
	first_sweep_direction:    engine.Particle_Group,
	second_sweep_direction:   engine.Particle_Group,
	final_gradient_stops:     [dynamic]engine.Color,
	final_gradient_steps:     [dynamic]int,
	final_gradient_direction: engine.Gradient_Direction,
}

sweep_config_default :: proc() -> Sweep_Config {
	cfg := Sweep_Config {
		first_sweep_direction    = .Column_R2L,
		second_sweep_direction   = .Column_L2R,
		final_gradient_direction = .Vertical,
	}
	append(&cfg.sweep_symbols, ..[]rune{'█', '▓', '▒', '░'})
	append(
		&cfg.final_gradient_stops,
		..[]engine.Color {
			engine.Color{0x8A, 0x00, 0x8A},
			engine.Color{0x00, 0xD1, 0xFF},
			engine.Color{0xff, 0xff, 0xff},
		},
	)
	append(&cfg.final_gradient_steps, 8)
	return cfg
}

sweep_parse :: proc(cfg: ^Sweep_Config, args: []string) -> bool {
	for i := 0; i < len(args); i += 1 {
		name, value, has_value := split_opt(args[i])
		switch name {
		case "--sweep-symbols":
			if !parse_symbols_flag(&cfg.sweep_symbols, args, &i, value, has_value) do return false
		case "--first-sweep-direction":
			if !parse_group_flag(&cfg.first_sweep_direction, args, &i, value, has_value) do return false
		case "--second-sweep-direction":
			if !parse_group_flag(&cfg.second_sweep_direction, args, &i, value, has_value) do return false
		case "--final-gradient-stops":
			if !parse_colors_flag(&cfg.final_gradient_stops, args, &i, value, has_value) do return false
		case "--final-gradient-steps":
			if !parse_ints_flag(&cfg.final_gradient_steps, args, &i, value, has_value) do return false
		case "--final-gradient-direction":
			if !parse_gdir_flag(&cfg.final_gradient_direction, args, &i, value, has_value) do return false
		case:
			fmt.eprintln("Error: unknown sweep option: ", name)
			return false
		}
	}
	return true
}

@(private = "file", rodata)
gray_shades := [5]engine.Color {
	{0xA0, 0xA0, 0xA0},
	{0x80, 0x80, 0x80},
	{0x40, 0x40, 0x40},
	{0x20, 0x20, 0x20},
	{0x10, 0x10, 0x10},
}

Sweep_State :: struct {
	config:         Sweep_Config,
	first_grays:    [dynamic]u8, // gray_codes index per particle and symbol
	second_colors:  [dynamic]u32, // second_codes index per particle and symbol
	gray_codes:     [5]engine.Appearance_Id,
	second_codes:   [dynamic]engine.Appearance_Id,
	final_codes:    [dynamic]engine.Appearance_Id, // per particle
	start_ticks:    [dynamic]int,
	active:         [dynamic]engine.Particle_Id,
	active_phase:   [dynamic]i8, // -1 inactive, 0 first lane, 1 second lane
	reveal:         engine.Group_Reveal,
	second_groups:  engine.Particle_Groups,
	first_phase:    bool,
	complete:       bool,
	color_handling: engine.Existing_Color_Handling,
	tick:           int,
}

sweep_build :: proc(s: ^Sweep_State, e: ^engine.Engine) {
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

	chars := engine.get_particles(
		engine.Particle_Query {
			e.particle_sets,
			e.particles.initial_coord[:len(e.particles)],
			e.canvas,
		},
		engine.PARTICLE_FILTER_ALL_FILLS,
		.Top_Bottom_Left_Right,
	)
	defer delete(chars)
	storage_len := len(e.particles)
	reserve(&s.active, len(chars))
	symbol_count := len(s.config.sweep_symbols)
	s.first_grays = make([dynamic]u8, storage_len * symbol_count)
	s.second_colors = make([dynamic]u32, storage_len * symbol_count)
	s.final_codes = make([dynamic]engine.Appearance_Id, storage_len)
	s.start_ticks = make([dynamic]int, storage_len)
	s.active_phase = make([dynamic]i8, storage_len)
	for i in 0 ..< storage_len {
		s.active_phase[i] = -1
		s.start_ticks[i] = -1
	}

	shades := gray_shades
	for shade, i in shades {
		s.gray_codes[i] = engine.prepare_appearance(e, {colors = {fg = shade}})
	}

	second_palette := make([dynamic]engine.Color, context.temp_allocator)
	defer delete(second_palette)
	switch s.color_handling {
	case .Dynamic:
		for id in e.particle_sets.input {
			style := engine.get_initial_appearance(e, id)
			if fg, ok := style.colors.fg.?; ok do append(&second_palette, fg)
			if bg, ok := style.colors.bg.?; ok do append(&second_palette, bg)
		}
		if len(second_palette) == 0 do append(&second_palette, ..spectrum[:])
	case .Ignore, .Always:
		append(&second_palette, ..spectrum[:])
	}
	unique_second, second_indices := engine.group_values(second_palette[:])
	defer delete(unique_second)
	defer delete(second_indices)
	unique_second_codes := make([]engine.Appearance_Id, len(unique_second), context.temp_allocator)
	defer delete(unique_second_codes, context.temp_allocator)
	for c, idx in unique_second {
		unique_second_codes[idx] = engine.prepare_appearance(e, {colors = {fg = c}})
	}
	s.second_codes = make([dynamic]engine.Appearance_Id, len(second_palette))
	for i in 0 ..< len(second_palette) {
		s.second_codes[i] = unique_second_codes[second_indices[i]]
	}

	final_styles := make([]engine.Appearance, len(chars), context.temp_allocator)
	defer delete(final_styles, context.temp_allocator)
	for id, k in chars {
		final: engine.Color_Pair
		switch s.color_handling {
		case .Dynamic:
			if (.Fill not_in e.particles.flags[id]) do final = engine.get_initial_appearance(e, id).colors
		case .Ignore, .Always:
			if (.Fill in e.particles.flags[id]) {
				final = {
					fg = engine.Color{0x00, 0x00, 0x00},
					bg = nil,
				}
			} else {
				final = {
					fg = engine.gradient_sample(
						sampler,
						spectrum[:],
						e.particles.initial_coord[id],
					),
					bg = nil,
				}
			}
		}
		final_styles[k] = {colors = final}
		lanes := int(id) * symbol_count
		for frame in 0 ..< symbol_count {
			s.first_grays[lanes + frame] = u8(engine.random_below(len(gray_shades)))
		}
		for frame in 0 ..< symbol_count {
			s.second_colors[lanes + frame] = u32(engine.random_below(len(s.second_codes)))
		}
	}
	if len(chars) > 0 {
		unique_finals, final_indices := engine.group_values(final_styles)
		defer delete(unique_finals)
		defer delete(final_indices)
		unique_final_codes := make([]engine.Appearance_Id, len(unique_finals), context.temp_allocator)
		defer delete(unique_final_codes, context.temp_allocator)
		for st, idx in unique_finals {
			unique_final_codes[idx] = engine.prepare_appearance(e, st)
		}
		for id, k in chars {
			s.final_codes[id] = unique_final_codes[final_indices[k]]
		}
	}

	s.reveal.groups = engine.get_particles_grouped(
		engine.Particle_Query {
			e.particle_sets,
			e.particles.initial_coord[:len(e.particles)],
			e.canvas,
		},
		engine.PARTICLE_FILTER_ALL_FILLS,
		s.config.first_sweep_direction,
	)
	s.reveal.ease = .Circular_In_Out
	s.reveal.duration = 100
	s.second_groups = engine.get_particles_grouped(
		engine.Particle_Query {
			e.particle_sets,
			e.particles.initial_coord[:len(e.particles)],
			e.canvas,
		},
		engine.PARTICLE_FILTER_ALL_FILLS,
		s.config.second_sweep_direction,
	)
	s.first_phase = true
}

sweep_next :: proc(s: ^Sweep_State, e: ^engine.Engine) -> bool #no_bounds_check {
	if len(s.active) == 0 && s.complete {
		return false
	}
	change := engine.group_reveal_step(&s.reveal)
	for gi in change.added.start ..< change.added.start + change.added.len {
		for id in engine.group_members(s.reveal.groups, gi) {
			if s.first_phase {
				engine.set_visible(e, id, true)
			}
			phase: i8 = s.first_phase ? 0 : 1
			if s.active_phase[id] < 0 do append(&s.active, id)
			s.active_phase[id] = phase
			s.start_ticks[id] = s.tick
		}
	}
	if engine.group_reveal_complete(s.reveal) {
		if s.first_phase {
			engine.groups_delete(&s.reveal.groups)
			s.reveal.groups = s.second_groups
			engine.group_reveal_reset(&s.reveal)
			s.first_phase = false
		} else {
			s.complete = true
		}
	}
	life := len(s.config.sweep_symbols) * 5 + 1
	write := 0
	for id in s.active {
		phase := s.active_phase[id]
		if phase < 0 do continue
		age := s.tick - s.start_ticks[id]
		if age % 5 == 0 do sweep_publish(s, e, id, phase, age / 5)
		if age + 1 == life {
			s.active_phase[id] = -1
		} else {
			s.active[write] = id
			write += 1
		}
	}
	resize(&s.active, write)
	s.tick += 1
	return true
}

// Each sweep shows its symbols in turn, five ticks apiece, then the particle's
// own glyph in that sweep's final colors.
sweep_publish :: proc(s: ^Sweep_State, e: ^engine.Engine, id: engine.Particle_Id, phase: i8, frame: int) #no_bounds_check {
	symbols := s.config.sweep_symbols[:]
	if frame == len(symbols) {
		engine.set_symbol(e, id, e.particles.initial_symbol[id])
		engine.set_appearance(e, id, phase == 0 ? s.gray_codes[1] : s.final_codes[id])
		return
	}
	lane := int(id) * len(symbols) + frame
	code := phase == 0 ? s.gray_codes[s.first_grays[lane]] : s.second_codes[s.second_colors[lane]]
	engine.set_symbol(e, id, symbols[frame])
	engine.set_appearance(e, id, code)
}
