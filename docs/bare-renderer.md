# Bare renderer experiment

The current implementation favors reducing engine state and code. It does not
meet the earlier performance-preservation target. The retained renderer and its
validated appearance API are preserved at JJ revision `495602e6`.

Particles contain placement, visibility, and visual IDs. Engine-owned visual
entries contain logical appearance and writable ANSI packets. Selecting a
prepared visual assigns an ID; independent edits use the particle's reserved
mutable entry. A shared-to-mutable transition preserves logical fields before
patching the packet. Long symbols are borrowed separately.

Setters mark a `[]bool` of dirty rows. Each frame clears only those rows in one
reusable particle-ID slice, clips visible particles, and places them directly
into dirty cells. Overlaps select the highest layer then particle ID. It emits
complete dirty rows, borrowing
packet slices and blank spans. Linux `writev` submits these slices; `frame_bytes`
provides an explicit contiguous capture for tests. Emit or capture a built frame
before changing particles or growing the visual table: output slices borrow that
storage and are not immutable frame snapshots.

Deleted renderer state includes cell membership links, dirty and selection
bitmaps, a separate previous-frame grid, emitted appearance snapshots, dynamic color
caches, and the concatenated CLI output buffer. There are no `raster_*` functions
or `mem.copy` calls in the engine. This does not mean zero data movement: packet
setters write fields, long symbols are borrowed, capture concatenates slices,
and the kernel transfers output bytes. The initial bare renderer used a sorted
draw list; the current implementation replaces that list with one current-frame
buffer and performs no render-time sorting.

Also removed the unused added-particle query list and the old renderer visual
comparison helper. Input, inner-fill, and outer-fill populations remain: Burn
and Laseretch query input plus inner fill, and Smoke includes outer fill only
when configured to cover the whole canvas. Particle batches still reserve build
capacity for Binarypath, Burn, Laseretch, and Thunderstorm.

## Validation

- 43 native optimized tests pass. The removed 44th test exercised only the
  deleted visual comparison helper.
- 222/222 terminal-state captures match the retained renderer: 37 effects with
  six fixtures covering plain input, no color, input color policies, xterm
  Unicode, and clipping/wrapping. The comparison checks per-frame cell state
  and final cursor position, not identical byte streams or intermediate cursor
  positions. It uses a terminal model, not a physical terminal emulator.
- `odin check` passes for the docs, accuracy, and parity tools.

## Initial sorted-renderer performance screen

Both binaries use `-o:speed -microarch:native`. The CLI screen uses dense 190x46
input, a 200x50 canvas, seed 1, unpaced output to `/dev/null`, CPU 2, three samples,
and a minimum sample duration of 0.3 seconds. This compares against our retained
renderer, not ttfx ASM. All effect frame counts match.

| Effect | Retained, best ms | Bare, best ms |
| --- | ---: | ---: |
| Colorshift | 29.5 | 99.4 |
| Decrypt | 54.3 | 571.9 |
| Waves | 29.4 | 105.9 |
| Rings | 193.3 | 614.0 |
| Middleout | 24.9 | 225.8 |
| Binarypath | 297.9 | 1957.7 |
| Burn | 62.8 | 2397.9 |
| Laseretch | 112.3 | 7661.0 |

The eight-effect geometric slowdown is approximately 9x; mean CPU time rises
from 100.4 to 1723.4 ms. Average peak RSS is 11.8 versus 11.9 MiB. Full-frame
collection, sorting, and output replace incremental work; sparse effects suffer
most. The screen predates the final
removal of the unused added-particle list and redundant placement comparisons.
Raw local results and source snapshots are under `/tmp/otfx-packets`.

## CPU profile of the simplified renderer

Profiled revision `1dae5641` with Odin `dev-2026-09-nightly:a2fb372`, built with
`-o:speed -microarch:native -debug`. Input, terminal dimensions, CPU affinity,
seed, and output destination match the screen above. `perf record` sampled
`cycles:u` at 997 Hz with DWARF call stacks (16 KiB). Laseretch and Burn each ran
once; Colorshift ran 30 complete invocations to collect enough samples.

| Effect | Samples | Approximate user-cycle share in sorting |
| --- | ---: | ---: |
| Laseretch | 7752 | 96% |
| Burn | 2375 | 94% |
| Colorshift | 2855 | 74% |

The dominant call is `slice.sort_by` in `build_draws` (`src/engine/render.odin`).
The installed Odin implementation converts the typed comparator into a generic
smoothsort comparator, potentially calls `less` twice per comparison, and moves
records through a generic byte-copy routine. Laseretch's comparator adapter alone
accounts for about 20% self samples. In Colorshift, `set_visuals` is only about
2.3% self samples. Inclusive percentages overlap and must not be added together.
Some inlined inclusive attribution in the repeated Colorshift run is inconsistent;
the smoothsort self samples alone account for 72.3%, supporting the same conclusion.

An independent three-run `perf stat` measurement of Laseretch reports mean wall
time 7.809 seconds and approximately 142.47 billion user instructions per run.
Each repetition reopens the input file. This is a CPU/output-submission workload;
`/dev/null` does not measure a terminal emulator, and `cycles:u` excludes kernel
execution. These results identify sorting as the first optimization target without
establishing how fast a replacement will be. No rendering algorithm was changed
during this profiling pass. Data, text reports, input, and timing results are saved
under `/tmp/otfx-profile`; the symbolized binary is `/tmp/otfx-perf-debug`.

## Removing the render sort (checkpoint `03dd01a0`)

This version owns one `[]Particle_Id` sized to the viewport. `compose_frame`
fills it with -1, then places each visible candidate directly at its terminal
cell, comparing layer and particle ID only when that cell is occupied. Emission
scans row slices, coalescing empty cells into blank spans. This removes `Draw`,
the dynamic draw list, its capacity management, sorting, and deduplication.
Composition plus emission is O(candidates + viewport cells), with no previous
frame or dirty-state machinery.

All 43 tests and the three tool checks pass. All 222 captures are byte-for-byte
identical to the sorted renderer, including the timed effects under a virtual
clock. These checks also cover selection order, empty selections, duplicate
candidates, overlap priorities, offscreen positions, and population growth.

Both comparison binaries use `-o:speed -microarch:native -debug`. The input,
affinity, samples, and output destination are the same as the earlier screen.
Best wall milliseconds:

| Effect | Sorted | Direct placement | Speedup |
| --- | ---: | ---: | ---: |
| Colorshift | 95.6 | 26.1 | 3.67x |
| Decrypt | 552.4 | 152.3 | 3.63x |
| Waves | 101.4 | 28.7 | 3.53x |
| Rings | 602.3 | 204.5 | 2.94x |
| Middleout | 225.4 | 28.1 | 8.01x |
| Binarypath | 1936.4 | 234.7 | 8.25x |
| Burn | 2276.0 | 145.5 | 15.64x |
| Laseretch | 7617.3 | 336.7 | 22.62x |

Geometric speedup is 6.51x. Mean CPU time is 1713.4 versus 144.4 ms and average
peak RSS is 11.9 versus 11.5 MiB. Frame counts match for all eight effects. This
compares two full-frame renderers; it does not establish parity with the older
incremental renderer or ttfx ASM. Captures, comparison harness, binaries, and
raw results are under `/tmp/otfx-direct`. The harness's historical `rust` column
means sorted Odin and its `odin` column means direct-placement Odin in this run.

## Dirty rows and fresh ASM comparison

The current renderer adds `dirty_rows: []bool`. Visual setters mark the current
visible row; movement marks both old and new rows; visibility and priority
changes mark the affected row. Composition clears and rebuilds only dirty rows,
and output writes each such row completely. A held frame has no row bytes.
There is still one cell buffer, no previous-frame copy, and no sort.

Particle mutations after the initial build must use setters. Direct effect
placement writes currently occur during build, while every row starts dirty.
Candidate-list changes also affect visibility without setters. A renderer-owned
one-byte `Frame_Selection` state per particle detects inclusion/removal and marks
the corresponding rows; candidate reordering and duplicates do not dirty rows.
This preserves the existing candidate API but requires scans each frame.

All 44 tests pass, including a new exact-output test for unchanged frames,
single-row edits, movement between rows, hiding, selection removal/re-entry,
duplicates, and offscreen movement. The 222 terminal-state captures match the
full-frame version. Output bytes intentionally differ because held rows are
omitted. The docs, accuracy, and parity consumers use the same composed cells.

Compared directly with full-frame checkpoint `03dd01a0` on the same eight-effect
screen, the geometric speedup is 0.95x (about 5% slower). Mean best wall time
changes from 144.5 to 162.7 ms and mean CPU from 144.6 to 164.2 ms. Decrypt
improves from about 152 to 103 ms, but Binarypath regresses from 234.9 to 335.1 ms
and Laseretch from 337.1 to 387.7 ms. Row dirtying saves output but is not an
overall speedup in this implementation. In a symbolized user-cycle profile of
eight Laseretch runs, the scan for removed candidates alone accounts for 13.2%
of samples; clipping and composition also remain significant.

A fresh 35-effect CLI comparison forces ttfx ASM with `TTFX_ASM=force`, using
`origin/asm-zen5` revision `ac940f2e11c95ef7e6d9e6d0c8b37d389a4e5e75`.
The verified release binary SHA256 is
`a1788a30978f735fd716ed30f5b2279bd07b4b89bb994c47c0b9612e1dab315c`.
Odin uses `-o:speed -microarch:native -debug`; both run pinned to CPU 2 with the
same 190x46 input, 200x50 canvas, seed 1, unpaced output to `/dev/null`, three
samples, and a 0.3-second minimum sample. Matrix and Thunderstorm are excluded
from the throughput aggregate because their duration is time-based.

| Metric | ttfx ASM | otfx dirty rows |
| --- | ---: | ---: |
| Mean best wall time | 54.7 ms | 103.1 ms |
| Mean child CPU time | 54.7 ms | 103.6 ms |
| Average peak RSS | 87.9 MiB | 10.4 MiB |
| Effects won | 32 | 3 |

ASM is 2.00x faster by geometric mean. otfx wins Binarypath, Overflow, and Slice.
Frame counts differ for 21 of 35 effects, so these are complete CLI workloads,
not identical per-frame simulations. `/dev/null` excludes terminal-emulator
cost. [Per-effect timings and frame counts](dirty-rows-asm-benchmark.tsv) are
checked in; raw logs, harnesses, captures, and profile data are in
`/tmp/otfx-rows`. The full-versus-dirty harness's historical `rust` column is
the full-frame Odin binary; the ASM harness's `rust` column is actual ttfx ASM.
