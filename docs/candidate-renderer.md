# Candidate-list renderer

The renderer now tracks the previous unique candidate IDs instead of scanning
the entire particle population twice for candidate membership. A changed
selection visits current and previous candidates; an unchanged explicit slice
uses `slice.equal`, and unchanged all-particle selection skips membership work.
Clipping and placement still visit current candidates.

The list is engine-owned because effects can overwrite their slice before the
next frame. Two alternating one-byte selection marks identify removals without
an overflowing generation counter. Duplicates and reordering preserve painter
order. Capacity follows particle storage during construction, including batches;
effects need no new reservation or publication API. No effect code changed.

## Paired CLI measurements

Both Odin binaries use `-o:speed -microarch:native -debug`, with bounds checks.
Baseline source is `b37d023e`. Dense input is 190 columns by 46 rows, terminal
environment is `COLUMNS=200 LINES=50`, seed 1, CPU affinity 2, and output goes to
`/dev/null` without pacing. Default input-derived canvas dimensions are 190x46.
The harness's old heading says "canvas 200x50"; those are terminal dimensions,
not explicit canvas dimensions. Three samples use batches lasting at least
0.3 seconds. CPU is child user plus system time from `wait4`.

| Metric, 35 finite effects | Before | Candidate list |
| --- | ---: | ---: |
| Mean best wall time | 102.8 ms | 93.4 ms |
| Mean CPU time | 103.1 ms | 93.3 ms |
| Average peak RSS | 10.4 MiB | 10.5 MiB |

Geometric speedup is **1.10x**. All 35 frame counts match; 32 effects improve.
Burn regresses 163.2 to 171.0 ms, Rain 66.4 to 70.0 ms, and Laseretch is roughly
flat at 392.5 to 393.3 ms. Print improves 120.3 to 66.7 ms, Binarypath 338.4 to
260.2 ms, and Decrypt 102.9 to 83.3 ms. These are complete effect invocations,
including build, playback, and output submission.
[All timings, frame counts, CPU and memory](candidate-benchmark.tsv).

## Fresh ttfx ASM comparison

Forced ASM uses `TTFX_ASM=force`, revision
`ac940f2e11c95ef7e6d9e6d0c8b37d389a4e5e75` (`origin/asm-zen5`). The release
binary SHA256 is
`a1788a30978f735fd716ed30f5b2279bd07b4b89bb994c47c0b9612e1dab315c`.
It is an exported checkout; the existing `third_party/ttfx` work was untouched.

| Metric | ttfx ASM | otfx candidate list |
| --- | ---: | ---: |
| Mean best wall time | 54.6 ms | 93.3 ms |
| Mean CPU time | 54.5 ms | 93.3 ms |
| Average peak RSS | 87.9 MiB | 10.7 MiB |
| Effects won | 32 | 3 |

ASM is **1.82x faster by geometric mean**. otfx wins Binarypath, Overflow,
and Slice. Frame counts differ for 21/35 effects, so this is not an identical
simulation or a pure renderer comparison. Matrix and Thunderstorm are excluded
because their durations depend on time. `/dev/null` excludes terminal-emulator
cost. [Per-effect results](candidate-asm-benchmark.tsv).

## Effect updates versus frame construction

The separate [phase diagnostic](../bench/phases/main.odin) reseeds and rebuilds
each effect five times, timing `next_frame` separately from `frame_build`.
It excludes initial build time, output syscalls, and temporary-memory cleanup.
Medians below include per-frame timer overhead and use separately compiled
binaries, so they diagnose attribution rather than replace the CLI benchmark.
The dimensions, seed, frame counts, candidate visits and output-part counts
match between these two runs.

| Effect | Update before / after, ms | Frame build before / after, ms |
| --- | ---: | ---: |
| Colorshift | 8.09 / 8.24 | 11.04 / 7.54 |
| Decrypt | 26.55 / 26.53 | 67.92 / 42.75 |
| Binarypath | 101.20 / 100.06 | 202.54 / 133.35 |
| Burn | 31.85 / 32.18 | 87.70 / 95.09 |
| Laseretch | 43.60 / 43.95 | 263.93 / 271.05 |
| Rain | 15.16 / 15.24 | 43.89 / 48.56 |

These regressions occur in rendering; the effect-update timings remain similar.
Rain grows its candidate list, while Burn and Laseretch combine a persistent
source prefix with a changing smoke/spark tail. The exact-equality shortcut
cannot skip that prefix when the tail changes. The remaining API opportunity is
to represent stable admission without repeatedly reconciling it; no new API is
introduced without a measured replacement. [Phase results](candidate-phases.tsv).

Reproduce the diagnostic using the benchmark's dense input file:

```sh
odin build bench/phases -o:speed -microarch:native -debug -out:/tmp/otfx-phases
COLUMNS=200 LINES=50 taskset -c 2 /tmp/otfx-phases INPUT_FILE
```

## What the ASM actually does

In the exported ASM source, `asm/effects/laseretch.asm:627` dispatches pending
etches and calls `update`; `asm/engine/update.asm:137` ticks active particles by
walking set bits. Our `laseretch_next` likewise updates active source and spark
lists. This source inspection has not established complete visual equivalence.

`asm/engine/render.asm:289` maintains cell membership when coordinates change;
`set_handle` updates the winning cell on appearance changes. `render_frame`
rebuilds cached row bytes only when needed. `emit_row` at line 490 uses four
unrolled visual loads and overlapping 32-byte stores, advancing by each visual's
actual length; larger visuals use 64-byte stores. It submits one iovec per row.
The output therefore benefits from SIMD copies and persistent cell/row state.
The header's old claim that movement forces a repaint is superseded by the
actual `coordinate_changed` / `cell_unlink` / `cell_link` implementation.

Our Laseretch run visits 52,839,005 candidate entries and creates 46,608,725
output parts over 14,307 frames. ASM produces 14,306 frames. Our effect updates
take about 44 ms, while frame construction alone takes 271 ms. Extra effect
math can contribute, but removing all effect-update work would still leave
frame construction above ASM's roughly 82 ms complete CLI run. Frame
construction itself also performs repeated coordinate/index arithmetic.

Five `perf stat` repetitions, pinned to CPU 2, measure these whole-run user
events (build included, kernel events excluded):

| Event | ttfx ASM | otfx |
| --- | ---: | ---: |
| CPU cycles | 411,068,373 | 1,751,301,949 |
| Instructions | 1,454,915,326 | 8,105,934,700 |
| Branches | 212,276,295 | 1,861,636,960 |
| Branch misses | 1,769,772 | 9,639,421 |

otfx executes 5.57x as many instructions and takes 4.26x as many user cycles.
These counters do not separate arithmetic from loads, bookkeeping, and checks,
nor establish equal work. Each repetition reopens stdin to avoid measuring an
empty-input invocation after the first run.

## Validation

All 46 native optimized tests pass, including caller-slice reuse, duplicates,
removal/re-entry, empty/all selection, population growth, overlap, and clipping.
All 222 captures match the preceding renderer byte for byte (37 effects,
six fixtures). These prove preservation of our prior behavior, not parity with
ttfx ASM. Playback allocation tests remain green. Raw sources, binaries,
captures, timings, and hardware-counter logs are in
`/tmp/otfx-candidates-20260926`.
