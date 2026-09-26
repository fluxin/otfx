# Flat composition and resolved row experiments

Historical experiments preceding checkpoint `495602e6`. The current working
implementation is the [bare renderer experiment](bare-renderer.md).

Neither prototype is retained. Both preserve deterministic output but regress
the representative eight-effect screen. The existing retained compositor and
direct writer are restored; earlier working-tree changes are preserved.

The retained change fixes cursor distances above 999. The decimal writer had
treated every value as at most three digits. Larger distances now use Odin's
`strconv.write_int` with stack storage. A regression test covers a 65,537-cell
canvas, sparse output at column 65,537, held frames, and a long symbol exceeding
the usual output reservation.

## Experiments

1. **Two flat grids.** Nonpositive priorities paint the base and positive
   priorities paint the overlay, preserving arbitrary priorities and creation
   order within each. Any membership change rebuilds both grids from character
   state, then compares the composed winners. Appearance-only changes still
   use the existing dirty-cell path. Character membership shrinks from 12 to
   4 bytes, but sparse movement now pays for scanning the population and grids.
2. **Resolved row slices with 16-bit handles.** Keep the retained compositor;
   stage changed appearances into a row-local table. The output consumer reads
   only handle slices, byte spans, and prepared/dynamic byte pools, with no
   character lookup. Prepared bytes are borrowed directly; dynamic bytes pass
   through a reusable row buffer. Rows wider than 65,535 cells use multiple
   chunks, so local handles do not limit canvas width or the global code pool.

The second prototype makes the boundary explicit, but constructs another table,
clears and scans row handles, and copies dynamic bytes twice. Its handle plane
is two bytes per cell; its transient appearance table also consumes memory.
Narrow handles alone do not establish a smaller or faster whole pipeline.

These experiments do not test a persistent resolved-appearance cache or a
compositor that retains the base and rebuilds only affected overlay regions.
They therefore do not rule out those designs. Any further implementation should
replace existing comparison/encoding work, rather than add staging after it.

## Measurement

All binaries are Odin builds using `-o:speed -microarch:native`. The comparison
baseline is the previously validated appearance-column/direct-writer binary,
SHA256 `e7bc58d4c9cd3d929682468ae9b9172f03edcc1c368e49ceb8fbd714bc221dd8`.
The harness retains its historical `rust`/`odin` labels, but **both sides here
are Odin**. This is not a new ttfx ASM measurement.

Real CLI runs use dense 190x46 input, a 200x50 canvas, seed 1, frame rate 0,
stdout `/dev/null`, CPU 2, three repeats, and minimum 0.3-second samples.
Comparisons run serially. The screen covers Colorshift, Decrypt, Waves, Rings,
Middleout, Binarypath, Burn, and Laseretch. All frame counts match.

| Experiment and effect | Baseline best wall | Prototype best wall |
| --- | ---: | ---: |
| Flat grids: Colorshift | 29.6 ms | 29.3 ms |
| Flat grids: Burn | 64.1 ms | 113.2 ms |
| Flat grids: Laseretch | 113.4 ms | 279.5 ms |
| Row handles: Colorshift | 29.8 ms | 36.9 ms |
| Row handles: Burn | 64.5 ms | 77.4 ms |
| Row handles: Laseretch | 113.7 ms | 159.0 ms |

Geometric speedup is 0.79x for flat grids and 0.84x for row handles: roughly 27%
and 19% more elapsed time, respectively. These rejected candidates were screened
on eight effects, not measured across the full finite suite. Complete screen
metrics are in [the measurements](row-composition-experiments.tsv).

The retained renderer plus cursor fix was measured across all 35 finite effects:
mean best wall time is 68.9 ms on both sides, mean child CPU is 68.7 versus
68.8 ms, and mean peak RSS is 11.2 MiB on both sides. Geometric speedup rounds
to 1.00x, and all 35 frame counts match. There is no measured performance gain
from this experiment. Raw results are in `/tmp/otfx-cells/final-full.txt`.

## Validation and artifacts

Flat grids passed the existing 43 tests and 222 byte-exact captures. Row handles
passed 44 tests, including the wide-canvas case, and 222 byte-exact captures.
The restored renderer with the cursor fix also passes all 44 tests and all 222
captures. Captures cover all 37 effects across plain, no-color, SGR always,
SGR dynamic, xterm Unicode, and clipped/wrapped inputs. Timed effects use the
virtual clock. Source and accuracy/parity/docs tools pass `odin check`.

Local artifacts are under `/tmp/otfx-cells`: `flat/` and `rows/` hold prototype
source and binaries; `before` is the baseline, `after` the retained result;
`flat-screen.txt` and `rows-screen.txt` hold raw measurements; `capture.py`,
`capture.log`, `rows-capture.log`, and `final-capture.log` retain capture evidence.
`bench/bench.odin` and `compare` are the path-adjusted benchmark harness.
