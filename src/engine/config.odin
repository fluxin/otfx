package engine

// Terminal configuration and input-color policy.

Terminal_Config :: struct {
	tab_width:                  int,
	xterm_colors:               bool,
	no_color:                   bool,
	existing_color_handling:    Existing_Color_Handling,
	wrap_text:                  bool,
	frame_rate:                 int,
	max_frames:                 Maybe(int),
	canvas_width:               int,
	canvas_height:              int,
	anchor_canvas:              Anchor,
	anchor_text:                Anchor,
	ignore_terminal_dimensions: bool,
	reuse_canvas:               bool,
	no_eol:                     bool,
	no_restore_cursor:          bool,
	virtual_clock:              bool,
	terminal_background_color:  Color,
}

// Existing input colors are either ignored, held at the renderer boundary, or
// consumed by an effect's own final lanes. Dynamic intentionally stays an
// effect decision: a global override would hide temporary effect visuals.
Existing_Color_Handling :: enum {
	Ignore,
	Always,
	Dynamic,
}

existing_color_handling_parse :: proc(s: string) -> (Existing_Color_Handling, bool) {
	switch s {
	case "ignore":
		return .Ignore, true
	case "always":
		return .Always, true
	case "dynamic":
		return .Dynamic, true
	}
	return .Ignore, false
}

config_default :: proc() -> Terminal_Config {
	return {
		tab_width = 4,
		frame_rate = 60,
		canvas_width = -1,
		canvas_height = -1,
		anchor_canvas = .Sw,
		anchor_text = .Sw,
		terminal_background_color = {0, 0, 0},
	}
}
