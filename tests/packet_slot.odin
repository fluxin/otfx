package regression

import "../src/engine"
import "core:testing"

@(test)
packet_writes_stay_inside_fixed_slots :: proc(t: ^testing.T) {
	glyphs := [5]rune{0, 'A', '¢', '▉', '😀'}
	styles := [4]engine.Appearance {
		{},
		{bold = true},
		{colors = {fg = engine.Color{17, 200, 255}}},
		{colors = {fg = engine.Color{0, 255, 9}, bg = engine.Color{100, 2, 30}}},
	}
	for no_color in ([2]bool{false, true}) {
		cfg := engine.config_default()
		cfg.no_color = no_color
		for initial_style, style_index in styles {
			style := initial_style
			engine.encode_appearance(&style, &cfg)
			for glyph, width in glyphs {
				backing: [55]byte
				for &b in backing do b = 0xa5
				slot_size := 4 if no_color else 51
				slot := backing[2:2 + slot_size]
				n := engine.packet_write(slot, glyph, &style, &cfg)
				expected := width
				if !no_color && style_index != 0 do expected += 47
				testing.expect_value(t, n, expected)
				for b in backing[:2] do testing.expect_value(t, b, u8(0xa5))
				for b in backing[2 + slot_size:] do testing.expect_value(t, b, u8(0xa5))
				for b in slot[n:] do testing.expect_value(t, b, u8(0))
			}
		}
	}
}
