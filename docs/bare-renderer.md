# Bare renderer experiment

The current implementation favors reducing engine state and code. It does not
meet the earlier performance-preservation target. The retained renderer and its
validated appearance API are preserved at JJ revision `495602e6`.

Particles contain placement, visibility, and visual IDs. Engine-owned visual
entries contain logical appearance and writable ANSI packets. Selecting a
prepared visual assigns an ID; independent edits use the particle's reserved
mutable entry. A shared-to-mutable transition preserves logical fields before
patching the packet. Long symbols are borrowed separately.

Each frame collects visible particles, clips them, sorts by terminal cell, and
resolves overlap by layer then particle ID. It emits complete rows, borrowing
packet slices and blank spans. Linux `writev` submits these slices; `frame_bytes`
provides an explicit contiguous capture for tests. Emit or capture a built frame
before changing particles or growing the visual table: output slices borrow that
storage and are not immutable frame snapshots.

Deleted renderer state includes cell membership links, dirty and selection
bitmaps, current/previous cell grids, emitted appearance snapshots, dynamic color
caches, and the concatenated CLI output buffer. There are no `raster_*` functions
or `mem.copy` calls in the engine. This does not mean zero data movement: packet
setters write fields, long symbols are borrowed, capture concatenates slices,
and the kernel transfers output bytes.

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

## Performance screen

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
