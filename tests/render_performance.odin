package regression

import "../src/engine"
import "core:testing"

@(test)
rounding_keeps_signed_even_ties :: proc(t: ^testing.T) {
	for c in ([]struct {
			x:        f64,
			expected: int,
		}{{-3.5, -4}, {-2.5, -2}, {-1.5, -2}, {-0.5, 0}, {0.5, 0}, {1.5, 2}, {2.5, 2}, {3.5, 4}, {-1.51, -2}, {-1.49, -1}, {1.49, 1}, {1.51, 2}, {-0.001, 0}, {0.001, 0}, {-1025.5, -1026}, {1025.5, 1026}, {1099511627776.5, 1099511627776}, {-1099511627776.5, -1099511627776}}) {
		testing.expect_value(t, engine.round_half_even(c.x), c.expected)
	}
}

@(test)
visual_comparison_preserves_all_fields :: proc(t: ^testing.T) {
	// Equal content at different addresses must compare equal. Palette/ID
	// identity and padding bytes are not the renderer's semantic authority.
	left, right := [3]u8{'a', 'b', 'c'}, [3]u8{'a', 'b', 'c'}
	visuals := []engine.Visual {
		{symbol = string(left[:])},
		{symbol = string(right[:])},
		{symbol = "d"},
		{symbol = "abc", fg = engine.Color{0, 0, 0}},
		{symbol = "abc", fg = engine.Color{255, 128, 1}},
		{symbol = "abc", bg = engine.Color{0, 0, 0}},
		{symbol = "abc", bg = engine.Color{255, 128, 1}},
		{symbol = "abc", bold = true},
		{symbol = "𐍈", fg = engine.Color{255, 128, 1}, bg = engine.Color{2, 3, 4}, bold = true},
	}
	for &a in visuals {
		for &b in visuals do testing.expect_value(t, engine.visual_equal(&a, &b), a == b)
	}
}
