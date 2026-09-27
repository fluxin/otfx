# Middleout animation and ownership comparison

2026-09-26. Checkpoint `3850833c` versus ASM `c2be6411`, with
`TTFX_ASM=force` and `TTFX_ASM_SHOW_TIER=1`; every reference run reported
ASM tier 4. No production source changes.

Both implementations start at the canvas center, expand to the center line,
then move home while fading. Both use maximum `(layer, particle ID)` as the
visible cell winner. Middleout does not draw random numbers.

Decoded every emitted frame from both real CLIs, accounting for their different
frame anchors, row movement, RGB SGR, and ignored NUL padding. Compared glyph,
foreground, background, bold, and dim at each cell; foreground and text
attributes on blank glyphs are normalized because they are not visible.
This decoder supports the observed output subset, not arbitrary terminal input.

- 24 small cases: all frames match. Plain and RGB-styled input, vertical and
  horizontal expansion, center/full speeds 0.6 and 100, and all three existing
  color modes, on a 20x6 canvas.
- Dense benchmark fixture: 235 frames each; 232 entire frames match.
  Frames 34 and 54 differ in one glyph each; frame 193 differs in three glyphs.
  Colors/styles at these cells match. Final canvases match. The exact numerical
  or ownership cause of the five glyph differences remains unisolated; this is
  close animation agreement, not exact frame parity.

The stack implementation is substantially different. Odin maintains sorted
dynamic cell arrays and uses binary search plus ordered shifting for interior
removal/insertion. ASM's `cell_link` prepends an unsorted list entry;
`cell_unlink` reads previous/next indices directly from per-particle arrays.
It does not search for the departing particle. If the departed particle was
the visible owner and multiple occupants remain, the cell is queued once;
`cell_rewin` finds the maximum after all frame changes. Covered-particle
departures require no winner scan. The important distinction is direct unlink
plus deferred winner selection, not linear search instead of binary search.

Evidence: `/tmp/otfx-middleout-asm-parity-20260926/compare.py`, `results.json`,
and `results.log`; source counterparts are `src/effects/middleout.odin` and
`/tmp/ttfx-asm-c2be6411/asm/{effects/middleout,engine/render}.asm`.
