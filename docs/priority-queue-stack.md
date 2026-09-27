# Odin standard priority queue as the cell stack

2026-09-27. Isolated experiment against checkpoint `0f71b549`.
Production source and previous experiments remain unchanged. Nothing committed.

## Result

The standard-library heap removes custom sorted insertion and compaction, but
is slower overall. Across two full 35-effect sweeps, arithmetic mean wall is
**31.737 → 32.656 ms (+2.89%)**.
Geometric time changes **+2.98%**.
Mean child CPU is 31.580 → 32.499 ms;
mean per-effect maximum RSS across the sweeps is 13233 →
13492 KiB. Preserve the prototype; do not promote it.

The first sweep develops visible timing variability: the unchanged baseline's
Spotlights and Swarm times rise, and some apparent wins change size or direction.
That triggered a second full sweep with both binary and effect order reversed.
Both sweeps are retained below; the aggregate averages them without discarding
slow samples. Variability also appears in the second sweep; reversing order did
not eliminate it. Treat small differences as uncertain. No cause of the variability
was established, and no claim of exclusive machine access is made.

| Sweep | Baseline mean ms | Heap mean ms | Geometric time change |
|---|---:|---:|---:|
| first | 31.623 | 32.411 | +2.85% |
| second | 31.851 | 32.900 | +3.15% |

This is a test of Odin's existing `core:container/priority_queue`, not a result
for every possible heap implementation. No new ASM timing was taken.

## Implementation

- Each cell holds `Priority_Queue(Render_Key)`. Reversing the comparison makes
  the highest `(layer, particle ID)` the root.
- Each particle has a renderer-owned `cell_slot: u32` column. It is meaningful
  while the particle belongs to a cell.
- Insertion uses `pq.push`; removal uses `pq.remove` at that known slot.
  The swap callback updates both particles' slot mappings whenever keys move.
- Cached `cell.top` is refreshed from the heap root. Only a changed winner
  dirties the cell through membership changes; content updates retain their
  existing visible-winner check.
- Delete `cell_compact`, `needs_compaction`, `compact_cells`, sorted insertion,
  and the frame-end compaction pass. No tombstones or separate arrival scratch.
- The queue callback has no user-data parameter. During `compose_frame`, a
  scoped `context.user_ptr` points to the engine and is restored afterward.
  This is an internal adaptation; the particle-facing API does not change.
- Initialize heaps with capacity zero, preserving lazy allocation of occupied
  cell storage rather than reserving 16 entries for every empty cell.

This maintains the heap eagerly on every membership change; it does not defer
ordering until the winner leaves. Source changes are confined to
`engine/render.odin`, `engine/engine.odin`, and `engine/particle.odin` in the
prototype. `render.odin` shrinks from 232 to 213 lines. The queue's stored
comparison/swap callbacks grow `Render_Cell` from **64 to 80 bytes**. A four-byte
heap-slot column is added per particle, and the engine's compaction array is
removed. No standard-library source was modified and no allocator was changed.

Heap repairs, callback calls, slot writes, cell layout and construction all
change together. Their individual contributions have not been isolated with
controls or profiling; the timings do not justify blaming only one of them.

## Protocol and full chart

Both frozen binaries: `-o:speed -microarch:native -debug`, assertions enabled,
existing scoped bounds exclusions retained. The standard queue keeps its own
checks. CPU 2, seed 1, terminal 200×50, dense input/default canvas 190×46,
frame-rate zero, stdout `/dev/null`. Whole CLI startup/build/playback/teardown
included; CPU and RSS from `wait4`. CPU 2 reports the performance governor.

Each full sweep has three batched samples per binary/effect targeting at least
0.3 seconds. First sweep: baseline first, effects ascending. Second sweep:
candidate first, effects descending. Table means average those two sweeps;
first/second change columns expose disagreement. No own build, capture or test
ran concurrently with timing. An additional seven-effect reversed screen uses
three 0.5-second samples and is retained separately in `reverse.log`, excluded
from this table and aggregate. All paired and between-sweep frame counts match.

[Raw chart with per-sweep wall/CPU/RSS/frame data](priority-queue-stack.tsv).
Positive changes mean slower.

| Effect | Before mean ms | Heap mean ms | Combined change | First change | Second change |
|---|---:|---:|---:|---:|---:|
| beams | 14.15 | 14.35 | +1.4% | +0.0% | +2.9% |
| binarypath | 164.50 | 180.80 | +9.9% | +8.7% | +11.1% |
| blackhole | 55.65 | 54.65 | -1.8% | -1.8% | -1.8% |
| bouncyballs | 33.65 | 35.35 | +5.1% | +5.4% | +4.7% |
| bubbles | 48.50 | 51.40 | +6.0% | +6.0% | +6.0% |
| burn | 21.85 | 22.75 | +4.1% | +5.1% | +3.2% |
| colorshift | 18.20 | 18.75 | +3.0% | +4.0% | +2.1% |
| crumble | 47.00 | 46.00 | -2.1% | +1.4% | -5.0% |
| decrypt | 25.10 | 26.35 | +5.0% | +1.2% | +8.5% |
| errorcorrect | 12.10 | 13.20 | +9.1% | +9.1% | +9.1% |
| expand | 20.85 | 18.50 | -11.3% | -9.9% | -12.6% |
| fireworks | 57.15 | 59.95 | +4.9% | +4.7% | +5.1% |
| highlight | 3.55 | 3.50 | -1.4% | -2.8% | +0.0% |
| laseretch | 43.80 | 46.30 | +5.7% | +5.7% | +5.7% |
| middleout | 15.90 | 14.55 | -8.5% | -8.2% | -8.8% |
| orbittingvolley | 19.00 | 20.40 | +7.4% | +7.4% | +7.4% |
| overflow | 10.90 | 12.30 | +12.8% | +12.8% | +12.8% |
| pour | 16.70 | 17.70 | +6.0% | +6.0% | +6.0% |
| print | 6.90 | 7.65 | +10.9% | +11.6% | +10.1% |
| rain | 20.40 | 21.75 | +6.6% | +6.0% | +7.1% |
| randomsequence | 4.00 | 4.00 | +0.0% | +0.0% | +0.0% |
| rings | 79.60 | 81.35 | +2.2% | +5.0% | -0.6% |
| scattered | 31.00 | 32.15 | +3.7% | +3.9% | +3.5% |
| slice | 6.05 | 7.20 | +19.0% | +16.7% | +21.3% |
| slide | 21.35 | 23.70 | +11.0% | +14.9% | +7.6% |
| smoke | 15.15 | 15.45 | +2.0% | +6.0% | -2.0% |
| spotlights | 35.35 | 36.60 | +3.5% | +6.8% | -0.3% |
| spray | 25.75 | 28.20 | +9.5% | +10.6% | +8.3% |
| swarm | 113.85 | 107.65 | -5.4% | -9.0% | -1.4% |
| sweep | 5.10 | 5.45 | +6.9% | +13.7% | +0.0% |
| synthgrid | 9.35 | 8.55 | -8.6% | -16.5% | +1.2% |
| unstable | 40.50 | 38.25 | -5.6% | -10.2% | +0.0% |
| vhstape | 29.90 | 29.30 | -2.0% | -5.6% | +2.2% |
| waves | 31.90 | 32.85 | +3.0% | +5.0% | +1.8% |
| wipe | 6.10 | 6.05 | -0.8% | -3.8% | +1.4% |

## Validation

- Changed prototype files formatted, `odin check` and optimized native build pass.
- **756/756 byte-identical captures**: 222 standard cases and
  534 combinations of options, seeds and existing-color handling, including
  virtual-clock weather cases.
- **82/86 tests pass**. The four existing allocation-test failures remain:
  `appearance_packet_survives_placement_changes`, `bounded_playback_reuses_build_storage`,
  `frame_composition_character_growth_is_amortized`, and `rebuilt_output_storage_does_not_grow`.
  Build allocation totals change after removing the compaction array.
  Logged per-effect playback allocation delta changes versus the baseline are
  `{'Expand': [71, 70], 'Middleout': [113, 105]}` (empty means no changed delta).
- The stack oracle independently checks membership, uniqueness, maximum-key
  winner, parent/child heap ordering, and every particle's recorded slot.
  Existing queued movement/layer-change tests are adapted to heap storage.
- **37/37 smoke cases pass**. Local Rust parity: 13 frame-count matches,
  24 diagnostic differences, zero failures. This is not a new ASM parity claim.

## Artifacts

Separate virtual-clock diagnostics use one logical second, three batched samples
targeting 0.3 seconds, with the same flags/input/affinity. They are excluded from
the finite-effect aggregate and subject to the timing variability noted above.

| Effect | Before/heap wall ms | Before/heap CPU ms | Before/heap peak RSS KiB | Frames both |
|---|---:|---:|---:|---:|
| Matrix | 66.9 / 60.8 | 66.6 / 60.6 | 10448 / 10636 | 1297 |
| Thunderstorm | 4.2 / 4.4 | 4.2 / 4.3 | 11884 / 11988 | 251 |

Preserved at `/tmp/otfx-priority-queue-20260927/`: full prototype `src` and `tests`,
`changes.patch` (all three production-source diffs), individual source/test
patches, frozen binaries, validation
scripts/logs/JSON, both full benchmark logs, the additional seven-effect screen,
and report scripts. `run_bench.py` runs the first sweep and targeted check;
`recheck.py` runs the reversed full sweep. Run Python scripts with `uv`.

```text
before 80b04054f4ca71f123d874b69c0d7ebe52190fa9ba65f283348e2fef1bfac0a8
after  a11f67641fe012042a30c7f21d89fea8e740a15d80b34eaaa9ee12228d8c882b
```
