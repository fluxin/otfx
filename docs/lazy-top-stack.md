# Lazy sorting after a cell loses its winner

2026-09-27. Isolated prototype against checkpoint `0f71b549`; production source
and earlier experiments remain unchanged. No commit made.

## Result

Middleout improves **15.8 → 7.2 ms (54.4%)**, with matching frames and bytes.
Across all 35 finite effects, arithmetic mean wall time is **30.300 → 30.409 ms
(0.36% slower)**; geometric time is **1.53% lower**. This is a promising Middleout
result, but not a general replacement yet. Binarypath, Scattered and Slide
regress in both the full sweep and reversed-order check.

Mean child CPU is 30.154 → 30.277 ms. Mean per-effect maximum RSS is
13,164 → 13,305 KiB. These are whole-CLI results, including build and teardown.
No new ASM measurement was taken.

## Implementation

Only the prototype's `src/engine/render.odin` changes production logic:

- Append incoming keys without binary search, insertion shifts, or merging.
- Retain both the winning particle ID and its actual array slot. New entries
  can sit after the winner; only greater `(layer, particle ID)` priority wins.
- Track whether append order is unsorted. Appearance changes do not sort.
- Pop directly when the stack is ordered and has no pending departures.
- When an unordered winner leaves, mark it invalid. Drain all particle updates
  first, compact departed entries, then quick-sort survivors once and select
  the last key. A new arrival above the old winner can resolve ownership without
  sorting, because the old winner's published key bounds every old survivor.
- Covered departures still compact once at the end of that frame, without
  sorting. This intentionally retains the current cleanup rule: retaining old
  entries across frames would allow same-cell/same-layer re-entry to resurrect
  them. Avoiding that cleanup needs an explicit tombstone, generation, or slot
  mechanism; this prototype does not add one.

There is no arrival scratch buffer and no particle API or layout change.
`Render_Cell` grows **64 → 72 bytes** for the tracked slot; two flags use existing
padding. The tests' stack oracle now checks ordering only when the stack claims
to be ordered, and independently checks every member, uniqueness, maximum key,
and winning slot. A new test covers a winner well before the array end, a higher
arrival, covered departure/re-entry, multiple winning departures, and subsequent
ordered popping.

The broad regressions cannot yet be assigned solely to sorting. Cell layout,
extra state maintenance, when cleanup runs, and compiler code generation all
change. The earlier bounded-insertion storage controls already showed that
layout alone can affect several effects. This experiment has no such isolated
layout control or new sampled profile, so those remain hypotheses.

## Full 35-effect chart

Both binaries use `-o:speed -microarch:native -debug`, assertions enabled and
existing scoped bounds exclusions. CPU 2, seed 1, terminal 200×50, dense input
and default canvas 190×46, frame-rate zero, output `/dev/null`. Three batched
samples per binary/effect, each targeting at least 0.3 seconds. No own build,
test or capture ran concurrently with timing. Means below are from the full
sweep, not mixed with the initial screen or reversed check. All frame counts
match. Small changes are not formal significance claims.

[Raw results including CPU, RSS and frame counts](lazy-top-stack.tsv).
Negative changes mean faster.

| Effect | Before mean ms | Lazy-top mean ms | Change |
|---|---:|---:|---:|
| beams | 14.1 | 14.3 | +1.4% |
| binarypath | 163.2 | 168.1 | +3.0% |
| blackhole | 55.5 | 53.5 | -3.6% |
| bouncyballs | 33.6 | 33.6 | +0.0% |
| bubbles | 48.4 | 49.2 | +1.7% |
| burn | 21.6 | 21.9 | +1.4% |
| colorshift | 17.5 | 17.4 | -0.6% |
| crumble | 41.8 | 41.1 | -1.7% |
| decrypt | 24.4 | 24.4 | +0.0% |
| errorcorrect | 12.1 | 12.2 | +0.8% |
| expand | 20.4 | 19.5 | -4.4% |
| fireworks | 57.0 | 56.5 | -0.9% |
| highlight | 3.4 | 3.4 | +0.0% |
| laseretch | 43.9 | 44.9 | +2.3% |
| middleout | 15.8 | 7.2 | -54.4% |
| orbittingvolley | 18.9 | 19.0 | +0.5% |
| overflow | 10.9 | 11.2 | +2.8% |
| pour | 16.7 | 16.8 | +0.6% |
| print | 6.9 | 6.9 | +0.0% |
| rain | 16.6 | 16.7 | +0.6% |
| randomsequence | 3.9 | 3.9 | +0.0% |
| rings | 79.1 | 81.8 | +3.4% |
| scattered | 30.8 | 32.6 | +5.8% |
| slice | 5.9 | 5.8 | -1.7% |
| slide | 17.3 | 18.3 | +5.8% |
| smoke | 13.5 | 13.5 | +0.0% |
| spotlights | 32.4 | 32.0 | -1.2% |
| spray | 23.6 | 23.8 | +0.8% |
| swarm | 107.0 | 108.7 | +1.6% |
| sweep | 5.0 | 5.0 | +0.0% |
| synthgrid | 8.3 | 8.3 | +0.0% |
| unstable | 36.9 | 38.3 | +3.8% |
| vhstape | 27.4 | 27.7 | +1.1% |
| waves | 22.3 | 22.3 | +0.0% |
| wipe | 4.4 | 4.5 | +2.3% |

## Reversed-order outlier check

Candidate first, baseline second; three batched samples targeting at least
0.5 seconds, otherwise identical. The table normalizes columns to before/after.

| Effect | Before mean ms | Lazy-top mean ms | Change |
|---|---:|---:|---:|
| wipe | 4.4 | 4.5 | +2.3% |
| slide | 17.3 | 18.4 | +6.4% |
| decrypt | 24.4 | 24.4 | +0.0% |
| scattered | 30.9 | 32.6 | +5.5% |
| binarypath | 162.7 | 169.3 | +4.1% |
| blackhole | 55.5 | 53.5 | -3.6% |
| middleout | 15.8 | 7.2 | -54.4% |

## Validation

- `odinfmt` on changed prototype files, `odin check`, optimized native debug build.
- **756/756 byte-identical captures:** 222 standard cases plus 534 combinations
  of options, seeds and existing-color modes, including virtual-clock weather.
- **83/87 unit tests pass**, including the added winner-slot test. The same four
  allocation tests fail as the baseline: `appearance_packet_survives_placement_changes`,
  `bounded_playback_reuses_build_storage`, `frame_composition_character_growth_is_amortized`,
  and `rebuilt_output_storage_does_not_grow`.
- Allocation failures are not unchanged in magnitude everywhere: the bounded
  playback test's Middleout delta rises **113 → 114**, Binarypath **292 → 319**;
  other logged effects retain their deltas. No claim of allocation-free playback.
- **37/37 smoke cases pass.** Parity against the unchanged local Rust reference:
  13 frame-count matches, 24 diagnostic differences, zero failures. This is not
  a new ASM animation-parity claim.

## Artifacts and reproduction

Separate virtual-clock diagnostics use one logical second, three batched samples
targeting 0.3 seconds, and otherwise the same benchmark setup:

| Effect | Before/after wall ms | Before/after CPU ms | Before/after peak RSS KiB | Frames both |
|---|---:|---:|---:|---:|
| Matrix | 62.6 / 62.6 | 62.4 / 62.4 | 10436 / 10444 | 1297 |
| Thunderstorm | 4.2 / 4.3 | 4.2 / 4.2 | 11884 / 11912 | 251 |

These are fixed logical workloads through `--virtual-clock`, excluded from the
35-effect aggregate; they are not real-time duration improvements.

All prototype sources, tests and scripts are preserved under
`/tmp/otfx-lazy-top-20260927/`:

- `src/engine/render.odin`, `render.patch`, `tests/lazy_top.odin`, `test-oracle.patch`.
- `before`, `after`, `bench`, `reverse`, `screen.log`, `full.log`, `reverse.log`.
- `capture.py`, `options.py`, capture JSON and logs, `tests.log`, `smoke.log`,
  `parity.log`, `clock.log`, `summary.json`.
- `run_bench.py` runs the 35-effect sweep and reversed seven-effect check.
  `report.py` writes the normalized TSV and summary. Run Python with `uv`.

Frozen binary SHA256:

```text
before 80b04054f4ca71f123d874b69c0d7ebe52190fa9ba65f283348e2fef1bfac0a8
after  6fb88c5db97c96afe4e616fec8a853d3a8823fc9354d09419eadd698cd14c369
```
