# Effect accuracy — 2026-09-25

Python TerminalTextEffects is the accuracy oracle; Rust ttfx is the performance
oracle. The target is close visual behavior: core motion, phase order, particle
behavior, color progression, and final content. Exact random paths, painter ties,
frames, and terminal bytes are not required. Performance tradeoffs need measured
benefits.

## Scope

- Python revision: `7a91dd9ca6ee0c4f4b1484efee0ecac1bb84104e`.
- All 37 effects complete on the centered Omarchy-logo fixture, 84×13 canvas,
  seed 3. Duration gates use a 60 Hz logical clock. Errorcorrect uses
  `--error-pairs 0.5`; other effect options are defaults.
- Twelve snapshots span each complete run, including its first and final frames.
  Each run is sampled over its own duration; tick labels matter when comparing
  timing. Seven effects match every sampled cell grid.
- Python snapshots come from one continuous run. Swarm can vary despite reseeding
  because of active-set ordering; rebuilding to select frames is unreliable.
- This is sampled visual review, not exhaustive seed, dimension, option, or style
  coverage. Short phases can fall between samples. Matching frame counts or final
  text alone does not establish visual accuracy.

## Accepted differences and option behavior

Native Odin easing is preferred to reproducing Python formulas. For example,
Scattered retains Odin's sine-based `Back_In_Out` rather than Python's polynomial;
its color progression is linear rather than exactly distance-synchronized.

Thunderstorm has independent strike/flash choreography. Its recursive branch
geometry and depth-first reveal order follow Python, but full-text flashes,
default-color restoration, spark cooling, and particle tails are not equivalent.
Equal-decision branch validation matched 6,279 coordinates, symbols, and child
insertion positions across 15 cases; that does not prove whole-effect equivalence.

Grouped Laseretch follows the intended alternating traversal. The reviewed Python
revision compares an enum with strings and does not reach that branch through its
CLI. Python exposes `final_gradient_frames` without reading it; Odin likewise
ignores that option. Default Laseretch is one spatial etching pass with concurrent
spark cooling, not two complete passes.

## Per-effect results

`Sampled` means the recognizable phases were present in the reviewed snapshots.
Frame counts are Python/Odin and are diagnostic, not performance ratios.

| Effect | Frames | Result |
|---|---:|---|
| Beams | 362/453 | Sampled: crossing beams, dim text, final wipe; random scheduling differs. |
| Binarypath | 905/799 | Sampled: binary travelers, collapse, dim reveal and final wipe. |
| Blackhole | 931/925 | Sampled: expansion/collapse paths, central pulse, distance fade, and final cooling. |
| Bouncyballs | 598/662 | Sampled: falling/bouncing particles, row progression and settling. |
| Bubbles | 1003/858 | Sampled: pop radius/motion, independent scenes, launch delay, and rainbow timing; random grouping differs. |
| Burn | 543/536 | Sampled: connected ignition and stretched fire glyph sequence. |
| Colorshift | 528/528 | All twelve sampled cell grids match exactly. |
| Crumble | 542/434 | Sampled: weaken, fall, vacuum, reassembly and flash; random cadence differs. |
| Decrypt | 930/984 | Sampled: typing, scrambling, gradual resolution. |
| Errorcorrect | 1579/1573 | Sampled: misplaced red glyphs, pair corrections and final colors. |
| Expand | 118/118 | Sampled: same expansion/fade; overlaps have different painter ties. |
| Fireworks | 1285/1231 | Sampled: launches, outward bloom, curved return and final fade. |
| Highlight | 129/129 | All twelve sampled cell grids match exactly. |
| Laseretch | 940/941 | Sampled: spatial traversal and simultaneous spark cooling. |
| Matrix | 1272/1317 | Sampled with logical clock: rain, filling, resolve. |
| Middleout | 134/134 | Sampled: fade completion; all twelve sampled cell grids match. |
| Orbittingvolley | 1079/1078 | Sampled: perimeter launchers and inward volleys. |
| Overflow | 42/75 | Sampled: random overflow rows followed by ordered final rows; random cycles/delays differ. |
| Pour | 482/482 | Sampled: serpentine rows and bouncing arrival; overlapping glyph ties differ. |
| Print | 805/805 | All twelve sampled cell grids match exactly. |
| Rain | 290/294 | Sampled: drops, landing and reveal. |
| Randomsequence | 264/264 | Sampled: scattered reveal and fades; random order differs. |
| Rings | 1398/1384 | Sampled: scatter/spin cycles and return. |
| Scattered | 183/189 | Sampled: scattered start, movement and color convergence. |
| Slice | 88/88 | All twelve sampled cell grids match exactly. |
| Slide | 138/132 | Sampled: row launches, movement and color progression. |
| Smoke | 231/226 | Sampled: irregular tree flood and stretched smoke glyph sequence. |
| Spotlights | 647/664 | Sampled: final radius; sampled search/convergence/expansion and matching final cells. |
| Spray | 423/430 | Sampled: randomized spray, arrival and final fade. |
| Swarm | 1938/1881 | Sampled: distance flashes, entry easing, interrupted motion, and retained tail glyphs; reference RNG remains set-sensitive. |
| Sweep | 220/220 | Sampled: grayscale first sweep and colored second sweep; random noise differs. |
| Synthgrid | 609/607 | Sampled: concurrency and one-block-per-tick launch cadence. |
| Thunderstorm | 964/911 | Independently choreographed strikes and flashes, not equivalent to Python. |
| Unstable | 304/345 | Sampled: rumble, heat, outward explosion, pause and reassembly. |
| Vhstape | 681/700 | Sampled: shifted/color-glitched lines, full snow phase, redraw; random glitches differ. |
| Waves | 553/553 | Sampled: symbol distribution; all twelve sampled cell grids match. |
| Wipe | 138/138 | All twelve sampled cell grids match exactly. |

## Reproduce and validate

```sh
odin build tools/accuracy -o:speed -out:/tmp/otfx-accuracy
uv run --no-project python tools/accuracy/capture.py \
  --odin /tmp/otfx-accuracy \
  --input "$HOME/.local/share/omarchy/logo.txt" \
  --out /tmp/otfx-accuracy-review
```

The tool captures paired JSON cells and SVG contact sheets without modifying the
reference checkouts. SVGs share a font and cell geometry; bold/dim input styling
is outside this plain-input review. The seven corrected gallery GIFs were
regenerated: Blackhole, Bubbles, Swarm, Waves, Synthgrid, Middleout, and Spotlights.

The latest optimization validation passes 30 tests and 463 exact before/after
Odin capture comparisons, including 32 expected empty-input refusals. Those checks
protect existing behavior across output modes, layouts, seeds, and edge cases;
they are separate from the sampled Python accuracy evidence above.
