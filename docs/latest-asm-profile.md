# Latest ASM: cost drivers and workload sensitivity

The Expand, Fireworks, and Swarm findings below describe the pre-correction
baseline. See [build/next corrections](build-contracts.md) for their current
implementation, validation, and timings.

2026-09-26. Comparison uses fetched `asm-zen5` revision `c2be6411` and the
current Odin engine after removing the TLSF experiment. The four affected
engine files were restored only after comparing them with the saved pre-TLSF
source; a full source-tree comparison then matched that snapshot. SIMD
rounding, Binarypath's pending-array change, and all other existing work remain.
The original four allocation tests remain failing (60/64 tests pass).

## What costs time

An optimized `-o:speed -microarch:native -debug` production-binary profile
covered Binarypath, Fireworks, Swarm, and Expand, fifteen full runs each.
These are diagnostic workloads, not the full 35-effect aggregate. Binarypath,
Fireworks, and Swarm alone account for about 27% of the summed time difference
in the preceding dense 35-effect comparison.

Our sampled user cycles split roughly into 46% in the main run procedure
(which inlines composition and cell patching), 29% in effect dispatch/update,
and another 8.5% in Swarm's update. Inlined cell removal, its linear search,
cell insertion, and the insertion's dynamic-array append account for about
20% combined. This is evidence of membership-maintenance cost, not evidence
that backing allocation consumes 20%.

Instrumented phase diagnostics support different bottlenecks by effect:

| Effect | Update ms | Compose ms | Patch/emit ms |
| --- | ---: | ---: | ---: |
| Expand | 18.3 | 13.4 | 2.6 |
| Binarypath | 72.6 | 128.9 | 47.9 |
| Fireworks | 82.2 | 24.5 | 9.8 |
| Swarm | 85.4 | 40.3 | 21.9 |

These are instrumented phase means, not production benchmark totals. The
stats build adds counters, timers, and an extra row-observation scan; its
playback total must not be compared directly with uninstrumented ASM.

Independent `perf stat` runs (ten full runs each of the same four effects,
one CPU, no concurrent build/test/profile) measured:

| User-mode counter | Odin | ASM | Odin/ASM |
| --- | ---: | ---: | ---: |
| Instructions | 83.06 billion | 39.85 billion | 2.08x |
| Cycles | 28.62 billion | 18.28 billion | 1.57x |
| Branches | 15.13 billion | 8.28 billion | 1.83x |
| Branch misses | 203.4 million | 191.7 million | 1.06x |
| Cache misses | 546.4 million | 551.6 million | 0.99x |

This supports excess executed work as a major driver; it does not establish
that cache stalls are irrelevant. Cross-engine frame counts differ for some
effects. ASM release symbols are stripped, so its sampled addresses were not
assigned speculative function names.

The source differences that fit the observations are:

- Our cell removal searches a layer bucket and performs ordered removal;
  insertion appends to a dynamic bucket. ASM keeps per-particle occupant
  links, unlinks directly, and defers winner resolution while replaying logs.
  Both representations still need to select an underlying winner.
- Our effects often calculate easing, positions, appearances, and invoke
  setters separately for each particle. Expand still visits its complete
  character list through the effect's last tick. ASM's new work batches path
  steps four/eight at a time, skips inactive work, and shares repeated eased
  shapes and visual sequences. These are source-supported explanations;
  the measurement does not isolate a percentage gain for each ASM commit.
- Both already retain output bytes. Laseretch was nearly tied in the
  dense comparison, and write time is small for the movement-heavy diagnostic
  effects. Changing allocator or syscall packaging alone cannot explain or
  close the broad gap.

## Effect build versus frame work

Expand's build stores final colors and per-character movement durations. Its
frame loop nevertheless reconstructs intermediate gradient colors and visits
already-arrived characters until the last one finishes. The ASM build creates
the reusable gradient visual sequence; playback visits the active set and
prunes completed paths/scenes. Our existing build/next split can express this
without introducing a generic event/path/scene engine: build reusable palettes,
retain active particle indices, and publish final coordinate/color/layer once
before retiring an index.

A build-state diagnostic counted Expand's loop work without altering its
effect implementation. At terminal 200x50 / canvas 190x46, 7,084 characters
and 302 ticks produce 2,139,368 visits. Only 1,131,752 are needed through the
arrival tick: **1,007,616 visits (47.1%) occur after arrival**. At terminal
320x90 / canvas 310x86, the redundant share is 46.6% (5,110,195 visits).
Skipping only ticks after final-state publication preserves the arrival
update. Precomputing reusable data and advancing only active work are already
the agreed build/next contract; this corrects an inconsistent implementation,
not a proposed new architecture.

Fireworks similarly revisits launched characters after their motion and color
sequences finish. Its frame loop repeatedly derives phase boundaries and
interpolates gradient colors. Swarm already maintains an active list; its
flashing movement branch computes the identical easing factor twice, once for
coordinates and once for color selection. These are effect implementation
issues, not a requirement for a new renderer API. Measure these effect-local
changes before concluding another shared-engine redesign is necessary.

## Usage boundaries

ASM takes runtime UTF-8 text and supports canvas dimensions, anchors,
wrapping, existing colors, xterm colors, and no-color mode. Its configured
effect symbols must be one Unicode codepoint; our rune-based effect symbol
API also requires one codepoint. This is not a requirement to recompile for
different text. Acceptance of CJK/emoji/combining input is not proof of
terminal display-width or grapheme correctness: the ASM input code advances
one column per codepoint.

There are additional ASM limits:

- At most 4,096 distinct input colors (`asm/engine/input.asm`).
- At most 256 parameters in one SGR sequence.
- A visual byte pool below 16 MiB, with 128-byte maximum encoded visuals.
- Custom cubic-Bezier easing and multi-codepoint configured symbols decline
  to Rust normally; `TTFX_ASM=force` makes decline an error.

The color/SGR limits and single-codepoint rule predate the latest changes.
The new Rust-to-ASM admission checks include extremely large Highlight widths
above 2^24 and Overflow cycle-range maxima above 2^20. Ordinary layout and
glyph variations are not excluded by those checks. Some resource limits
inside ASM are fatal errors, rather than safe Rust fallback.

Runtime checks with `TTFX_ASM=force` confirmed acceptance of the Unicode/SGR
fixture with wrapping, centered text, explicit 40x12 canvas, dynamic colors,
xterm colors, and no-color mode. CJK/emoji/combining input also executed,
without establishing display-width correctness. A 4,097-distinct-color input
executed in Odin but ASM exited 101 with `too many distinct input colors`.
These checks used three frames and establish admission, not full visual parity.

## Size and glyph measurements

All figures below use the restored engine without TLSF. The first four rows
are full 35-effect arithmetic means of best batched wall time:

| Terminal | Input/default canvas | Content | ASM ms | Odin ms | Odin/ASM |
| --- | --- | --- | ---: | ---: | ---: |
| 80x24 | 70x20 | Dense ASCII | 4.6 | 5.5 | 1.19x |
| 200x50 | 190x46 | Dense ASCII | 30.8 | 47.9 | 1.56x |
| 320x90 | 310x86 | Dense ASCII | 133.2 | 226.0 | 1.70x |
| 200x50 | 190x46 | Mixed 2/3/4-byte Unicode | 33.0 | 49.2 | 1.49x |

Input grows proportionally with the terminal: this measures complete effect
scaling with more particles and a larger canvas, not clipping the same fixed
particle population at different viewport sizes. Unicode replaces non-space
ASCII codepoints while retaining the same spaces and line lengths. It also
changes glyph diversity, so it does not isolate UTF-8 encoding cost alone.

Mean child CPU (ASM/Odin) for these rows is 4.5/5.4, 30.7/48.3,
133.1/227.5, and 33.0/49.4 ms. Mean per-effect peak RSS is 33.5/5.5,
50.6/13.2, 94.4/34.4, and 53.4/13.1 MiB. Laseretch at the largest size is
267.1/208.0 ms, favoring Odin, while Expand is 74.0/192.5 ms with identical
506-frame counts. There is no universal per-effect advantage.

Two additional eight-effect screens used Beams, Binarypath, Expand,
Fireworks, Laseretch, Print, Swarm, and Wipe:

- Unicode plus RGB SGR and `--existing-color-handling always`: ASM 77.1 ms,
  Odin 100.8 ms, mean CPU 77.1/101.1 ms, mean peak RSS 98.3/15.7 MiB.
- A small sparse 111-byte, eight-line input at terminal 80x24: ASM 1.2 ms,
  Odin 0.7 ms; geometric speedup favors Odin by approximately 1.8x. Mean CPU
  is 1.1/0.7 ms and mean peak RSS 32.7/3.9 MiB. Startup is a substantial
  fraction of such short runs. This screen is not a 35-effect aggregate.

Every workload forced ASM (no silent Rust fallback), used CPU 2, seed 1,
frame rate 0, three batched samples with a 0.15-second minimum, and output to
`/dev/null`. This isolates engine/CLI work from terminal-emulator cost.
Matrix/Thunderstorm ran one-second diagnostic windows and remain outside
the 35-effect summaries. No build, test, or profiling job ran during timing.
Both engines completed the finite-effect runs; differing frame counts are
preserved in the tables rather than treated as equal-work throughput.

Full per-effect wall/CPU/RSS/frame counts (reference=ASM, candidate=Odin):

- [80x24](latest-asm-size-80.tsv)
- [200x50](latest-asm-size-200.tsv)
- [320x90](latest-asm-size-320.tsv)
- [Unicode](latest-asm-unicode.tsv)
- [Unicode with SGR, eight effects](latest-asm-unicode-sgr.tsv)
- [Small sparse input, eight effects](latest-asm-sparse.tsv)

Post-removal `odin check src` passed, and the restored optimized binary
matched the frozen pre-TLSF binary in all 222 exact captures. The 60/64
unit-test result remains the four original allocation failures; this work
does not claim those failures are fixed.

## Artifacts

`/tmp/otfx-latest-asm-profile-20260926` contains the restored optimized binary,
source of the temporary fixture-aware benchmark harness, input fixtures,
per-effect raw timing logs, phase TSV, perf data/reports/counters, and the
runtime usage-check script/results. The production benchmark harness was
not modified.
