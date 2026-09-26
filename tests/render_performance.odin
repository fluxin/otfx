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
