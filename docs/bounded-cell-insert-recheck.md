# Bounded insertion: longer, reversed-order recheck

2026-09-27. No production source or frozen candidate changes. Repeats the
preallocated bounded-merge prototype against checkpoint `0f71b549`.

## Result

The broad result repeats: **0.56% worse arithmetic mean time**, **0.83% better
geometric time**. Middleout's large improvement coexists with repeatable losses
in Binarypath, Rings, Scattered and several smaller effects. Spotlights changes
direction between the two orders; its previous small regression is not robust.
The prototype remains isolated and uncommitted.

| Six-sample mean across 35 effects | Before | Candidate |
|---|---:|---:|
| Wall, ms | 30.306 | 30.476 |
| Child CPU, ms | 30.166 | 30.336 |
| Mean per-effect maximum RSS, KiB | 13322 | 13413 |

Seven effects have lower combined mean wall time. Twelve have a greater-than-2%
loss in both orders, including small 0.1–0.2 ms differences: Binarypath, Decrypt,
Highlight, Orbittingvolley, Randomsequence, Rings, Scattered, Spray, Sweep,
Synthgrid, Waves and Wipe. These are observed repeated differences, not statistical
confidence intervals. No ASM timing was rerun.

## Protocol and full chart

Three batched samples per binary per effect, each targeting at least 0.5 seconds,
in each of two sweeps. The first sweep runs baseline then candidate, effects
ascending. The second runs candidate then baseline, effects descending. The
chart averages the mean wall times from both sweeps: **six batched samples per
binary**, rather than picking the faster order or comparing individual launches.

Both use `-o:speed -microarch:native -debug`, assertions enabled, existing scoped
bounds exclusions, CPU 2, seed 1, dense terminal 200x50/default canvas 190x46,
frame-rate zero, `/dev/null`. Whole CLI startup/build/playback/cleanup included.
CPU and RSS use native `wait4`; CPU 2's governor reported `performance`. No own
build, test, capture or diagnostic ran concurrently with benchmark timings.

Negative percentages mean faster. Forward/reverse percentages use each sweep's
mean wall time. All frame counts match. [Raw per-effect data](bounded-cell-insert-recheck.tsv).

| Effect | Before mean ms | Candidate mean ms | Combined change | Forward change | Reverse change |
|---|---:|---:|---:|---:|---:|
| beams | 13.90 | 14.15 | +1.8% | +2.2% | +1.4% |
| binarypath | 162.55 | 167.65 | +3.1% | +2.9% | +3.4% |
| blackhole | 55.55 | 53.40 | -3.9% | -4.0% | -3.8% |
| bouncyballs | 33.45 | 34.00 | +1.6% | +1.5% | +1.8% |
| bubbles | 48.45 | 48.80 | +0.7% | +1.0% | +0.4% |
| burn | 21.60 | 21.95 | +1.6% | +1.4% | +1.9% |
| colorshift | 17.45 | 17.65 | +1.1% | +1.1% | +1.1% |
| crumble | 41.85 | 41.85 | +0.0% | -0.2% | +0.2% |
| decrypt | 24.30 | 25.15 | +3.5% | +3.7% | +3.3% |
| errorcorrect | 12.10 | 12.20 | +0.8% | +0.8% | +0.8% |
| expand | 20.35 | 19.40 | -4.7% | -4.9% | -4.4% |
| fireworks | 57.20 | 57.35 | +0.3% | +0.0% | +0.5% |
| highlight | 3.40 | 3.50 | +2.9% | +2.9% | +2.9% |
| laseretch | 43.70 | 44.40 | +1.6% | +1.6% | +1.6% |
| middleout | 15.80 | 7.40 | -53.2% | -53.2% | -53.2% |
| orbittingvolley | 18.90 | 19.40 | +2.6% | +2.6% | +2.6% |
| overflow | 10.90 | 11.05 | +1.4% | +1.8% | +0.9% |
| pour | 16.65 | 16.75 | +0.6% | +1.2% | +0.0% |
| print | 6.90 | 6.80 | -1.4% | -1.4% | -1.4% |
| rain | 16.60 | 16.85 | +1.5% | +1.2% | +1.8% |
| randomsequence | 3.90 | 4.10 | +5.1% | +5.1% | +5.1% |
| rings | 79.15 | 81.70 | +3.2% | +3.3% | +3.2% |
| scattered | 30.75 | 32.40 | +5.4% | +5.2% | +5.5% |
| slice | 5.90 | 6.00 | +1.7% | +1.7% | +1.7% |
| slide | 17.35 | 16.65 | -4.0% | -4.0% | -4.0% |
| smoke | 13.50 | 13.70 | +1.5% | +1.5% | +1.5% |
| spotlights | 33.20 | 33.00 | -0.6% | +2.2% | -3.2% |
| spray | 23.70 | 24.50 | +3.4% | +3.4% | +3.4% |
| swarm | 107.20 | 109.10 | +1.8% | +1.8% | +1.8% |
| sweep | 5.00 | 5.20 | +4.0% | +4.0% | +4.0% |
| synthgrid | 8.30 | 8.60 | +3.6% | +3.6% | +3.6% |
| unstable | 37.00 | 37.10 | +0.3% | +0.3% | +0.3% |
| vhstape | 27.45 | 27.25 | -0.7% | -1.1% | -0.4% |
| waves | 22.30 | 23.05 | +3.4% | +3.6% | +3.1% |
| wipe | 4.40 | 4.60 | +4.5% | +4.5% | +4.5% |

## Correctness rerun

- `odin check` passes for both source trees.
- Both unit suites: **82/86 pass**; same four allocation-test failure names.
- 222 standard plus 534 option/seed/color captures: **756/756 byte-identical**.
- Supported-effect smoke matrix: **37/37 pass for each binary**.
- Both parity tools: **13 frame-count matches, 24 diagnostic differences,
  zero failures**, against the local Rust reference. This is completion/final
  content validation, not an assertion of identical ASM animation.
- All 35 finite-effect frame counts match in both timing orders.

The four failing tests are `appearance_packet_survives_placement_changes`,
`bounded_playback_reuses_build_storage`,
`frame_composition_character_growth_is_amortized`, and
`rebuilt_output_storage_does_not_grow`. Build allocation counts differ. In the
bounded-playback test's per-effect logs, only Middleout's playback allocation
delta changes: 113 before versus 114 after. Other logged playback deltas match.
The three other named tests retain the same extra allocation counts (1, 12 and
21 respectively). This does not claim allocation-free rendering or fix the tests.

## Matrix and Thunderstorm

Separate one-logical-second virtual-clock diagnostics; three 0.5-second batched
samples, otherwise the same native harness and CPU affinity. They are excluded
from the 35-effect means.

| Effect | Mean wall before/after ms | CPU before/after ms | RSS before/after KiB | Frames |
|---|---:|---:|---:|---:|
| Matrix | 62.5 / 62.7 | 62.3 / 62.5 | 10444 / 10612 | 1297 / 1297 |
| Thunderstorm | 4.2 / 4.3 | 4.2 / 4.2 | 11796 / 12108 | 251 / 251 |

## Storage controls: why fewer shifts can still lose time

A separate control keeps the original renderer algorithms but adds the candidate's
72-byte cell layout and population-sized preallocated scratch. No batching or
bounded merging occurs. Three 0.3-second samples per binary:

| Effect | Baseline mean ms | Old renderer + new storage mean ms |
|---|---:|---:|
| Colorshift | 17.4 | 17.4 |
| Decrypt | 24.4 | 25.1 |
| Wipe | 4.5 | 4.6 |
| Scattered | 30.8 | 32.0 |
| Binarypath | 163.0 | 169.9 |

A second control restores the original 64-byte cell layout while keeping the
same scratch allocation/growth code and original renderer. In a direct paired
comparison, 72-byte / 64-byte mean times are: Decrypt 25.1/25.5, Scattered
31.9/31.7, Binarypath 170.8/167.1, Wipe 4.6/4.6, Colorshift 17.4/17.4.
Both controls pass their 30 targeted exact-byte captures.

**Inference:** much of the loss can occur without the new batching algorithm.
Returning to 64-byte cells helps Binarypath, but does not consistently restore
all effects. These controls do not isolate cache behavior, instruction layout,
compiler decisions or build-time scratch management from one another. Do not
attribute every loss to sorting, or claim the larger cell is the sole cause.
A further targeted profile/control is needed before choosing the next fix.

## Artifacts

All logs, frozen binaries, captures, test binaries, parity tools, two control
source trees and report generator: `/tmp/otfx-range-recheck-20260927`.
`forward.log` is before/candidate; **`reverse.log` labels are candidate/before**;
the TSV normalizes them. `layout.log` is baseline/storage-control;
`scratch.log` is 72-byte/64-byte storage controls. Counter/diagnostic binaries
were not used for throughput measurement.

SHA256:

- Before: `80b04054f4ca71f123d874b69c0d7ebe52190fa9ba65f283348e2fef1bfac0a8`
- Candidate: `289ff667f1d776540c8566fed1c1a2ed4bece3f933dda7616d5c4cb52d17d15c`

The benchmark builds use `REFERENCE_BENCH_BINARY` and `OTFX_BENCH_BINARY` set to
those frozen files, swapped for `reverse`. Both full sweeps run
`BENCH_MIN_SECONDS=0.5 taskset -c 2 <harness> 3 <all 35 finite effects>`.
Weather wrappers prepend `--virtual-clock`; their harness sets
`BENCH_MATRIX_RAIN_TIME=1 BENCH_STORM_TIME=1` and runs Matrix/Thunderstorm only.
