package engine

// Decode input text and terminal escapes, then materialize input particles.

Input_Error :: enum {
	None,
	Invalid_Tab_Width,
	Unsupported_Escape,
	Unsupported_SGR,
	Unsupported_Cursor,
}

Input_Cell :: struct {
	symbol: rune,
	style:  Appearance,
}

Line :: struct {
	cells: [dynamic]Input_Cell,
	width: int,
}

input_style_has_color :: #force_inline proc(style: Appearance) -> bool {
	return style.colors.fg != nil || style.colors.bg != nil
}

preprocess_input :: proc(input: string, tab_width: int) -> ([]Line, Input_Error) {
	if tab_width <= 0 do return nil, .Invalid_Tab_Width
	lines: [dynamic]Line
	append(&lines, Line{})
	row, col := 0, 0
	active: Appearance
	standard_fg: Maybe(int)

	ensure :: proc(lines: ^[dynamic]Line, row, col: int) {
		for len(lines^) <= row do append(lines, Line{})
		l := &lines^[row]
		for len(l.cells) <= col do append(&l.cells, Input_Cell{symbol = ' '})
	}

	runes := to_runes(input)
	defer delete(runes)
	i := 0
	for i < len(runes) {
		r := runes[i]
		if r == '\x1b' {
			if i + 1 >= len(runes) || runes[i + 1] != '[' {
				return nil, .Unsupported_Escape
			}
			end := input_csi_end(runes, i)
			if end == 0 do return nil, .Unsupported_Cursor
			final := runes[end - 1]
			params_end := i + 2
			for params_end < end - 1 &&
			    runes[params_end] >= '\x30' &&
			    runes[params_end] <= '\x3f' {
				params_end += 1
			}
			params := runes[i + 2:params_end]
			intermediates := runes[params_end:end - 1]
			if final == 'm' {
				if len(intermediates) != 0 || !input_apply_sgr(params, &active, &standard_fg) {
					return nil, .Unsupported_SGR
				}
			} else if !input_private_mode(params, intermediates, final) {
				if !input_apply_cursor(params, intermediates, final, &row, &col) {
					return nil, .Unsupported_Cursor
				}
			}
			i = end
			continue
		}
		if r == '\n' {
			row += 1
			col = 0
			ensure(&lines, row, 0)
			i += 1
			continue
		}
		if r == '\r' {
			col = 0
			i += 1
			continue
		}
		count := 1
		symbol := r
		if r == '\t' {
			symbol = ' '
			count = tab_width - col % tab_width
		}
		for _ in 0 ..< count {
			ensure(&lines, row, col)
			lines[row].cells[col] = {symbol, active}
			col += 1
		}
		i += 1
	}

	for &l in lines do l.width = len(l.cells)
	for &l in lines {
		for l.width > 0 {
			last := l.cells[l.width - 1]
			if last.symbol != ' ' || input_style_has_color(last.style) do break
			l.width -= 1
		}
	}
	for len(lines) > 0 && lines[len(lines) - 1].width == 0 do pop(&lines)
	if len(lines) == 0 do append(&lines, Line{width = 0})
	return lines[:], .None
}

to_runes :: proc(s: string) -> []rune {
	out: [dynamic]rune
	for r in s do append(&out, r)
	return out[:]
}

// The caller admits only ESC [. Zero denotes an incomplete or malformed CSI.
input_csi_end :: proc(runes: []rune, start: int) -> int {
	t := start + 2
	for t < len(runes) && runes[t] >= '\x30' && runes[t] <= '\x3f' do t += 1
	for t < len(runes) && runes[t] >= '\x20' && runes[t] <= '\x2f' do t += 1
	if t < len(runes) && runes[t] >= '\x40' && runes[t] <= '\x7e' do return t + 1
	return 0
}

input_private_mode :: proc(params, intermediates: []rune, final: rune) -> bool {
	if len(intermediates) != 0 || len(params) != 3 || params[0] != '?' do return false
	if final != 'h' && final != 'l' do return false
	return (params[1] == '2' && params[2] == '5') || (params[1] == '7' && params[2] == '0')
}

input_apply_cursor :: proc(params, intermediates: []rune, final: rune, row, col: ^int) -> bool {
	if len(intermediates) != 0 || (len(params) > 0 && params[0] == '?') do return false
	for p in params {
		if (p < '0' || p > '9') && p != ';' do return false
	}
	d := csi_default_param(params)
	switch final {
	case 'A':
		row^ = max(0, row^ - d)
	case 'B':
		row^ += d
	case 'C':
		col^ += d
	case 'D':
		col^ = max(0, col^ - d)
	case 'E':
		row^ += d; col^ = 0
	case 'F':
		row^ = max(0, row^ - d); col^ = 0
	case 'G':
		col^ = max(0, d - 1)
	case 'H', 'f':
		row^ = max(0, csi_param(params, 0) - 1)
		col^ = max(0, csi_param(params, 1) - 1)
	case:
		return false
	}
	return true
}

input_apply_sgr :: proc(params: []rune, active: ^Appearance, standard_fg: ^Maybe(int)) -> bool {
	values: [dynamic]int
	defer delete(values[:])
	if len(params) == 0 {
		append(&values, 0)
	} else {
		value := 0
		for p in params {
			if p == ';' {
				append(&values, value)
				value = 0
			} else if p >= '0' && p <= '9' {
				value = value * 10 + int(p - '0')
			} else {
				return false
			}
		}
		append(&values, value)
	}

	i := 0
	for i < len(values) {
		p := values[i]
		switch {
		case p == 0:
			active^ = {}
			standard_fg^ = nil
		case p == 1:
			active.bold = true
			if standard, ok := standard_fg^.?; ok do active.colors.fg = xterm_to_rgb(u8(standard - 30 + 8))
		case p == 22:
			active.bold = false
			if standard, ok := standard_fg^.?; ok do active.colors.fg = xterm_to_rgb(u8(standard - 30))
		case p == 39:
			active.colors.fg = nil
			standard_fg^ = nil
		case p == 49:
			active.colors.bg = nil
		case p >= 30 && p <= 37:
			active.colors.fg = xterm_to_rgb(u8(p - 30 + (active.bold ? 8 : 0)))
			standard_fg^ = p
		case p >= 90 && p <= 97:
			active.colors.fg = xterm_to_rgb(u8(p - 90 + 8))
			standard_fg^ = nil
		case p >= 40 && p <= 47:
			active.colors.bg = xterm_to_rgb(u8(p - 40))
		case p >= 100 && p <= 107:
			active.colors.bg = xterm_to_rgb(u8(p - 100 + 8))
		case p == 38 || p == 48:
			if i + 1 >= len(values) do return false
			is_fg := p == 38
			mode := values[i + 1]
			color: Color
			switch mode {
			case 5:
				if i + 2 >= len(values) || values[i + 2] < 0 || values[i + 2] > 255 do return false
				color = xterm_to_rgb(u8(values[i + 2]))
				i += 2
			case 2:
				if i + 4 >= len(values) do return false
				for component in values[i + 2:i + 5] {
					if component < 0 || component > 255 do return false
				}
				color = {u8(values[i + 2]), u8(values[i + 3]), u8(values[i + 4])}
				i += 4
			case:
				return false
			}
			if is_fg {
				active.colors.fg = color
				standard_fg^ = nil
			} else {
				active.colors.bg = color
			}
		}
		i += 1
	}
	return true
}

csi_param :: proc(params: []rune, index: int) -> int {
	field := 0
	value := 0
	has := false
	for r in params {
		if r == ';' {
			if field == index do return has ? value : 1
			field += 1
			value, has = 0, false
		} else if r >= '0' && r <= '9' {
			value = value * 10 + int(r - '0')
			has = true
		}
	}
	if field == index do return has ? value : 1
	return 1
}

csi_default_param :: proc(params: []rune) -> int {
	return max(csi_param(params, 0), 1)
}

setup_input_particles :: proc(e: ^Engine, lines: []Line) {
	// The decoded input already gives the population. Allocate/zero the SoA
	// columns once instead of growing and scattering a complete row per glyph.
	count := 0
	for line in lines {
		for cell in line.cells[:line.width] {
			if cell.symbol != ' ' || input_style_has_color(cell.style) do count += 1
		}
	}
	first := len(e.particles)
	assert(u64(first) + u64(count) <= u64(NO_PARTICLE), "particle count exceeds 32-bit IDs")
	set_first := len(e.particle_sets.input)
	resize(&e.particles, first + count)
	reserve(&e.updates, cap(e.particles))
	resize(&e.particle_sets.input, set_first + count)
	written := 0
	// Wrap by walking the original cells. No copied lines or retained suffixes.
	wrap_width := max(e.canvas.right, 1)
	input_height := len(lines)
	if e.cfg.wrap_text do input_height = wrapped_line_count(e.input_line_widths[:], wrap_width)
	row_index := 0
	for line in lines {
		column := 0
		for col0 in 0 ..< line.width {
			if e.cfg.wrap_text && column == wrap_width {
				column = 0
				row_index += 1
			}
			column += 1
			cell := line.cells[col0]
			if cell.symbol == ' ' && !input_style_has_color(cell.style) {
				continue
			}
			id := first + written
			initial := cell.style
			if e.cfg.existing_color_handling == .Always do e.particles.flags[id] += {.Preserve_Initial_Colors}
			init_particle(
				e,
				Particle_Id(id),
				cell.symbol,
				prepare_appearance(e, initial),
				coord(column, input_height - row_index),
			)
			// Input starts with the glyph alone; its original style remains available
			// to the configured color policy and effect transitions.
			set_appearance(e, Particle_Id(id), Appearance{})
			e.particle_sets.input[set_first + written] = Particle_Id(id)
			written += 1
		}
		row_index += 1
	}
	anchor_text(e, e.particle_sets.input[:], e.cfg.anchor_text)
}
