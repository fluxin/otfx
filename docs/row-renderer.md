# Incremental cell ownership and row bytes

The 35-effect CLI benchmark falls from **93.2 to 48.2 ms mean best wall time**
against frozen otfx `f75ea5a5`. Mean child CPU falls from 93.1 to 48.1 ms;
average peak RSS grows from 10.7 to 11.3 MiB. Geometric speedup is **1.83×**.
All 35 frame counts are unchanged; 34 effects improve.

A fresh forced-ASM comparison measures **54.5 ms ASM versus 48.2 ms otfx**,
about 12% less mean time. otfx wins 19/35; geometric mean is **1.01×**, essentially
a tie. This meets the mean-time target, not a claim that otfx is faster on every
effect. Matrix and Thunderstorm are excluded because their normal completion
uses elapsed time. Terminal-emulator work is excluded by `/dev/null` output.

## API and implementation

Effects now return `bool` from `next_frame`/`*_next` and publish changes through
existing particle/appearance setters. Six redundant `render_ids` arrays and
their maintenance are removed. Visibility is the admission authority; the engine
still supports optional explicit selections for tools and tests. A strict audit
of the old candidate API found no visible, in-viewport omission in all 222
capture cases before the API was removed.

The engine maintains cell occupants and the current winner incrementally.
Appearance updates preserve membership; movement, visibility, layer, and explicit
selection changes update it. There is no per-frame walk of all selected particles
when admission is unchanged. A winning appearance can patch equal-length row
bytes immediately; cells already pending replacement are handled once at frame
build. Other sparse changes splice exact byte lengths; dense rows rebuild once.
Dirty cells use Odin's `bit_array`; packet fields use `bit_set`. No padded glyph
slots or extra unused bytes are sent.

Emission is one slice per dirty row plus cursor moves, retaining `writev` retries.
Capture concatenation remains an explicit consumer. Long strings are supported
without truncation. Setter equality guards remain. Renderer storage is reserved
by the engine; effects do not reserve renderer arrays or manually mark dirtiness.
See [the API and ownership contract](architecture.md).

Shared optimizations include paired SIMD coordinate rounding, inline appearance
publication, and one placement publication after compound particle updates.
Rings samples colors only when its gradient changes; Middleout separates motion
from color cadence; Decrypt retires completed discovered-color tails. Completion,
random order, and emitted frames remain unchanged.

## Experiments

[Experiment measurements](row-experiments.tsv) distinguish screens from complete
35-effect runs. Screen populations vary and must not be compared as aggregates.
Every trial uses the same frozen baseline, not the preceding trial.

| Trial | Measurement | Decision |
|---|---|---|
| A: generic contiguous append | 8-effect geometric 0.92×; resizing per packet 0.86× | Reject per-packet append/resize overhead. |
| A3: reserve once, write with cursor | Full 35 mean 96.7 → 88.0 ms | Useful emission control, superseded by row storage. |
| B2: rebuild dirty rows into persistent bytes | 8-effect 1.02× | Insufficient alone. |
| B1: equal-length patch, whole-row fallback | 8-effect 1.06× | Insufficient while composition still scans candidates. |
| C: incremental ownership, old candidate API | Full 35 mean 96.1 → 72.5 ms | Retain ownership; remove redundant effect selection. |
| C4: sparse cell splicing and dense row rebuild | Full 35 mean 93.2 → 63.2 ms | Retain adaptive row emission. |
| Deferred placement or deferred winner resolution | Extra state; unchanged or worse screen aggregate | Reject. |
| Effect cadence, SIMD rounding, shared setter work | Final full 35 mean 93.2 → 48.2 ms | Retain. |
| Additional placement inlining / cached-cell lookup | No useful screen gain | Reject. |

The dense-row threshold is more than one eighth of row width, at least one cell.
It is a measured heuristic, not a claim of optimality for every workload. The
final engine deliberately retains ownership bookkeeping because removing the
candidate scan and repeated row encoding paid for its cost across the suite.

## Regressions and comparison limits

Overflow is the sole regression against frozen otfx: **18.9 → 24.6 ms** in the
full run. A longer reversed-order run (five samples, minimum one second) measured
**19.0 → 28.7 ms**, confirming rather than dismissing the regression. Its profile
attributes substantial cost to appearance publication and cell link/unlink work
while it moves many complete rows repeatedly. The extra inlining trial did not
resolve it. This remains an explicit limitation of the retained renderer.

[All before/after results](row-benchmark.tsv) and [all ASM results](row-asm-benchmark.tsv)
include wall time, child CPU, peak RSS, and frame markers. ASM is still faster on
16 effects, including Beams, Burn, Print, Spotlights, and Sweep. Frame counts
differ in 21/35 ASM comparisons, so these are whole-animation CLI costs, not
identical simulation throughput or proof of matching visual choreography.

## Phase accounting

[Instrumented phases](row-phases.tsv) include three samples per effect. Timers
separate update, compose, emit, and write; `other_ms` charges observation scans,
temp cleanup, timer bookkeeping, and loop overhead. Their sum equals measured
playback time. Initialization is excluded. Instrumentation scans emitted cells
for diagnostics, so its total is intentionally slower than the production CLI.

Laseretch, 14,307 frames, medians:

| Metric | Before | After |
|---|---:|---:|
| Effect update, including setters | 45.36 ms | 34.60 ms |
| Compose | 203.22 ms | 0.90 ms |
| Emit | 83.17 ms | 22.37 ms |
| Write | 83.22 ms | 6.31 ms |
| Dirty rows/frame, average / peak | 30.73 / 46 | 30.73 / 46 |
| Descriptors/frame including origin, average / peak | 3,258.8 / 8,147 | 73.14 / 92 |
| Actual writev calls | 52,686 | 14,307 |
| Output bytes | 1,756,264,786 | 1,756,264,786 |

The old compose scan visited 52,839,005 selected entries (excluding its additional
membership reconciliation). The new run makes 31,742 admission visits and
168,758 occupant visits during winner resolution. It patches 904,914 cells and
builds only the initial 46 rows; variable-length patches shift their suffixes.
The byte-copy counter includes those suffix shifts, not just changed glyphs.
Ownership and immediate appearance work now occurs inside setters and is charged
to update time. A low compose time alone is therefore not the speedup evidence;
the full CLI comparison is.

## Hardware counters

[Five-repetition perf counters](row-counters.tsv) cover Laseretch, Colorshift,
Burn, and Print for baseline, candidate, and ASM. Events are user-space cycles,
instructions, cache misses, dTLB load misses, branches, and branch misses.
Counters multiplex at about 82–84% and report their running percentages and
variation. `stalled-cycles-backend` is unsupported on this machine; no backend
stall count is inferred from instruction counts.

For Laseretch, instructions fall from **8.11 billion to 0.90 billion**, versus
ASM's **1.46 billion**. User cycles fall from **1.89 billion to 0.31 billion**,
versus ASM's **0.44 billion**. Cache misses also fall sharply; dTLB measurements
have high variation. These are complete CLI runs including build. Every perf
repetition reopens stdin; no repeated run consumes an exhausted input stream.

## Validation and reproduction

- `odin check src`; native `odin test tests`: **47/47**.
- Native tests with `-define:OTFX_FRAME_STATS=true`: **47/47**, including allocation gates.
- **222/222 byte-identical captures** against frozen otfx: all 37 effects across
  plain, no-color, existing SGR Always/Dynamic, xterm/Unicode, and clipped/wrapped fixtures.
- Parity tool: **37 effects, zero failures**; 13 identical frame counts and 24
  diagnostic differences from the non-ASM reference.
- Accuracy/docs tool checks pass. The new row-byte test exercises sparse/dense
  updates, growth/shrinkage, empty and long symbols, color changes, and repeated
  edits before emission. Existing tests cover clipping, priority, selection
  removal/re-entry, duplicate IDs, growth, long strings, and allocation-free playback.

Both frozen Odin binaries use `-o:speed -microarch:native -debug`, with bounds
checks. Hardware is Ryzen 9 9900X3D; Odin is `dev-2026-09-nightly:a2fb372`.
Full CLI runs are sequential on CPU 2, three samples each, minimum 0.3 seconds,
seed 1, frame rate 0. Input/default canvas is **190×46**, with terminal environment
`COLUMNS=200 LINES=50`. The old harness heading said canvas 200×50; the maintained
harness now distinguishes terminal and input dimensions. No compilation, capture,
or test run overlaps a measured benchmark.

ASM is the exported `origin/asm-zen5` revision
`ac940f2e11c95ef7e6d9e6d0c8b37d389a4e5e75`, forced with `TTFX_ASM=force`.
The existing `third_party/ttfx` checkout and its work in progress were untouched.
Frozen binary SHA256:

- before: `3e1a051da1f924636ec95b0f3263add5a5a0ead4ff47077d86687b989298665e`
- after: `4e701e07e5e0b5857826c5c0f256b85029cec3b10518dfeb2fa7211840fba677`
- ASM: `a1788a30978f735fd716ed30f5b2279bd07b4b89bb994c47c0b9612e1dab315c`

```sh
odin build src -o:speed -microarch:native -debug -out:/tmp/otfx-after
odin build bench -o:speed -define:OTFX_BENCH_BINARY=/tmp/otfx-after -define:REFERENCE_BENCH_BINARY=/tmp/otfx-before -out:/tmp/otfx-compare
BENCH_MIN_SECONDS=0.3 taskset -c 2 /tmp/otfx-compare 3
# Select the exported ASM binary as REFERENCE_BENCH_BINARY for the ASM comparison.
TTFX_ASM=force BENCH_MIN_SECONDS=0.3 taskset -c 2 /tmp/otfx-asm-compare 3
odin build bench/phases -o:speed -microarch:native -debug -define:OTFX_FRAME_STATS=true -out:/tmp/otfx-phases
COLUMNS=200 LINES=50 taskset -c 2 /tmp/otfx-phases INPUT_FILE --print > /dev/null
uv run bench/capture.py /tmp/otfx-before /tmp/otfx-after
```

Raw trial sources, frozen binaries, captures, profiles, and logs remain in
`/tmp/otfx-emission-20260926`. The retained source was reformatted after freezing
its benchmark binary; this did not change behavior.
