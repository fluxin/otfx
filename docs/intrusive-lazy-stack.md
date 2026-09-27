# Intrusive cell lists with lazy sorting

2026-09-27. Original isolated measurements against checkpoint `0f71b549`.
The user subsequently approved copying this implementation into the working tree.
See the [integrated benchmark](intrusive-main.md) for the current results and
queue cleanup. All comparison experiments remain intact; the original isolated experiment
made no commit.

## Result

This is the strongest aggregate result of the recent cell-stack experiments:
35-effect mean wall **30.386 → 28.954 ms
(-4.71%)**, with **5.06%
lower geometric time**. Mean child CPU is 30.234 → 28.823 ms.
Mean per-effect maximum RSS is 13201 → 12511 KiB
(-5.2%). Individual RSS changes differ; the
TSV includes every effect's memory result.

Middleout roughly halves its time while Blackhole, Binarypath, Scattered,
Expand and Fireworks also improve. The reversed-order check repeats the main
gains and Slide's regression. **Slide, Overflow and Smoke remain outliers**;
the user accepted copying this tradeoff into the working tree. Laseretch's
small 0.7% loss in the full sweep is also disclosed.

All **87 tests pass**, including the four allocation tests that failed with the
baseline. All **756 capture cases are byte-identical**. No ASM binary was
rebuilt or timed in this experiment.

## Data and operations

- A **24-byte `Render_Node` per particle** contains Odin's `list.Node` and the
  published packed `(layer, particle ID)` key. The particle struct/API is unchanged.
- Engine-owned `xar.Array(Render_Node, 2)` keeps node addresses stable across
  growth. Nodes are indexed by particle ID. The installed xar implementation's
  chunk table at SHIFT=2 can address the existing full u32 particle-ID range.
  This uses the standard library unchanged and does not restrict scene size to
  the benchmark population.
- A **40-byte `Render_Cell`**, down from 64, holds the intrusive list header,
  cached winning particle ID, unordered/pending flags and borrowed byte slice.
  Keeping the existing winning ID avoids a second cached pointer/ID pair.
- Incoming particles append in O(1), updating the winner when their key is
  larger. An append below the existing tail marks the list unordered.
- Covered departures unlink their exact node immediately through its neighbors.
  There is no membership search, tombstone, or frame-end compaction.
- An ordered winner departure reveals the remaining tail directly. An unordered
  winner departure queues that cell once and temporarily clears its winner.
  Subsequent arrivals/departures are drained before resolution.
- Resolution gathers surviving keys into **one reusable engine-owned scratch
  array**, sorts that array with `sort.quick_sort` when necessary, reconnects
  the same stable nodes, and selects the last key. Nodes never move during sorting.
- `render_prepare` prepares storage after engine construction and effect build.
  Composition has an O(1) population-length check and prepares new nodes only
  when particle creation has grown the population. Thunderstorm therefore uses
  the same path; its dynamic strike/spark growth can still allocate.
- Scratch reserves against particle capacity during preparation; the frame's
  gather/sort/relink work reuses it. Temporary allocator reset policy is unchanged.

Original prototype production-code changes are limited to `engine/render.odin`,
`engine/engine.odin`, and one automatic preparation call in `effects/effect.odin`.
No effect-specific animation logic changes. The old compaction queue becomes a
winner-resolution queue. Per-cell dynamic stacks, insertion shifts and compaction
are removed, but stable storage and scratch preparation add code:
`render.odin` is **232 → 254 lines**, so this is not a net source-code deletion.

## Full 35-effect chart

Both frozen binaries: `-o:speed -microarch:native -debug`, assertions enabled,
existing scoped bounds exclusions retained. Standard xar lookup checks remain.
CPU 2, seed 1, terminal 200×50, dense input/default canvas 190×46, frame-rate zero,
output `/dev/null`. Whole CLI build/playback/teardown included. Child CPU and
peak RSS come from `wait4`.

Full sweep: three batched samples per binary/effect targeting at least 0.3
seconds, baseline then candidate. No own build, test or capture ran concurrently
with timings. A six-effect initial screen and seven-effect reversed-order check
are separate; their numbers are not mixed into the full aggregate. The reversed
check uses three samples targeting 0.5 seconds. All finite-effect frame counts match.
Small differences are observations, not formal significance claims.

[Raw full results with CPU, RSS and frame counts](intrusive-lazy-stack.tsv).
Negative changes mean faster.

| Effect | Before mean ms | Intrusive mean ms | Change |
|---|---:|---:|---:|
| beams | 14.0 | 13.8 | -1.4% |
| binarypath | 163.6 | 158.3 | -3.2% |
| blackhole | 55.6 | 50.1 | -9.9% |
| bouncyballs | 33.6 | 33.5 | -0.3% |
| bubbles | 48.5 | 48.2 | -0.6% |
| burn | 21.7 | 21.6 | -0.5% |
| colorshift | 17.5 | 17.1 | -2.3% |
| crumble | 41.9 | 37.6 | -10.3% |
| decrypt | 24.3 | 24.3 | +0.0% |
| errorcorrect | 12.1 | 12.1 | +0.0% |
| expand | 20.4 | 17.5 | -14.2% |
| fireworks | 57.2 | 52.1 | -8.9% |
| highlight | 3.4 | 3.3 | -2.9% |
| laseretch | 43.8 | 44.1 | +0.7% |
| middleout | 15.9 | 7.6 | -52.2% |
| orbittingvolley | 19.0 | 18.1 | -4.7% |
| overflow | 11.0 | 11.3 | +2.7% |
| pour | 16.7 | 16.6 | -0.6% |
| print | 6.9 | 6.9 | +0.0% |
| rain | 16.6 | 16.5 | -0.6% |
| randomsequence | 3.9 | 3.8 | -2.6% |
| rings | 79.2 | 74.3 | -6.2% |
| scattered | 30.8 | 29.3 | -4.9% |
| slice | 6.0 | 5.4 | -10.0% |
| slide | 17.4 | 18.2 | +4.6% |
| smoke | 13.5 | 13.8 | +2.2% |
| spotlights | 33.1 | 32.0 | -3.3% |
| spray | 23.8 | 23.8 | +0.0% |
| swarm | 107.2 | 102.2 | -4.7% |
| sweep | 5.0 | 4.9 | -2.0% |
| synthgrid | 8.4 | 8.3 | -1.2% |
| unstable | 37.0 | 33.6 | -9.2% |
| vhstape | 27.6 | 27.2 | -1.4% |
| waves | 22.4 | 21.7 | -3.1% |
| wipe | 4.5 | 4.3 | -4.4% |

## Reversed-order check

Candidate first, baseline second; the table normalizes to before/after.

| Effect | Before mean ms | Intrusive mean ms | Change |
|---|---:|---:|---:|
| wipe | 4.5 | 4.3 | -4.4% |
| slide | 17.4 | 18.2 | +4.6% |
| decrypt | 24.6 | 24.3 | -1.2% |
| scattered | 30.8 | 29.4 | -4.5% |
| binarypath | 162.8 | 158.3 | -2.8% |
| blackhole | 55.6 | 50.4 | -9.4% |
| middleout | 15.9 | 7.6 | -52.2% |

## Correctness and allocation checks

Additional reversed-order checks for the smaller outliers use three 0.5-second
batched samples. Smoke repeats at **13.5 → 13.8 ms (+2.2%)**; Overflow is
**11.0 → 11.2 ms (+1.8%)**, versus +2.7% in the full sweep. These are small
absolute costs (0.2–0.3 ms), but their direction repeats.

- Formatting of changed prototype files, `odin check`, native optimized debug build.
- **87/87 unit tests pass.** Existing allocation assertions remain active.
  The two pre-existing assertion-test arena-leak warnings still appear; passing
  tests do not claim every lifetime or unbounded weather run is allocation-free.
- The four baseline failures now pass: `appearance_packet_survives_placement_changes`,
  `bounded_playback_reuses_build_storage`, `frame_composition_character_growth_is_amortized`,
  and `rebuilt_output_storage_does_not_grow`.
- The storage oracle independently checks unique membership, both link directions
  through predecessor/tail consistency, published keys, ordered-list claims,
  and maximum-key winner. Existing full-paint reference checks remain.
- The old per-cell stack-capacity reuse check now checks combined node/scratch
  capacity stability. Its assertions were adapted to the new representation,
  rather than replacing capacity with a constant.
- New regression: grow to 1,025 linked particles, check the original node address
  survives, remove/re-enter a covered particle, remove the winner while another
  particle changes layer, then pop and re-enter again. Validate membership and
  winner throughout.
- **756/756 exact captures**, including 222 standard cases and
  534 option/seed/color combinations. Weather captures use a virtual clock.
- **37/37 smoke cases pass.** Local Rust parity: 13 frame-count matches,
  24 diagnostic differences, zero failures. This is not a new ASM parity claim.

## Artifacts

Separate virtual-clock diagnostics use one logical second and three batched
samples targeting 0.3 seconds. They are excluded from the 35-effect aggregate.

| Effect | Before/intrusive wall ms | Before/intrusive CPU ms | Before/intrusive peak RSS KiB | Frames both |
|---|---:|---:|---:|---:|
| Matrix | 63.2 / 58.2 | 63.0 / 58.0 | 10436 / 10068 | 1297 |
| Thunderstorm | 4.3 / 4.2 | 4.2 / 4.1 | 11804 / 11920 | 251 |

Preserved at `/tmp/otfx-intrusive-lazy-20260927/`: prototype `src` and `tests`,
`changes.patch` (all production-source changes), individual source/test patches,
frozen binaries, capture JSON/logs, `tests.log`, `parity.log`, `smoke.log`,
`screen.log`, `full.log`, `reverse.log`, `outliers.log`, `clock.log`, and scripts.
`run_bench.py` reproduces the full sweep and seven-effect reverse check. Run
Python scripts with `uv`. The working tree now includes this migration; the
prototype and these original measurements remain frozen.

```text
before 80b04054f4ca71f123d874b69c0d7ebe52190fa9ba65f283348e2fef1bfac0a8
after  03dbaadf5dc2acc54de1b003d94eee7dd28ae09d5ea574af645c027c5508a01e
```
