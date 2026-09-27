# Per-cell compaction and arrival merge experiment

2026-09-26. Isolated source and binaries under
`/tmp/otfx-cell-batch-20260926/`, based on checkpoint `3850833c`.
Production source is unchanged; neither version was deleted or committed.

## Implementation

Gather the deduplicated particle updates first, writing final cell membership.
Each affected cell records its original stack length once; new arrivals are
appended after that sorted prefix. Then visit each affected cell once:

1. Copy arrivals into one reusable scratch array.
2. Check arrival order; sort only the arrivals if they are not already sorted.
3. Compact the old sorted prefix, retaining particles whose final cell and
   layer still match its keys.
4. Merge the arrivals and sorted survivors backward into the retained stack.
5. Compare final versus previous winner and dirty the cell when it changes.

Content updates to the retained winner still dirty it. No renderer API or
effect code changes. Ordered cell membership and layer/ID painter ties remain.
Departures-only cells do not sort; they compact their old occupants once.
This is not the earlier whole-stack bulk-sort experiment.

The prototype adds an original-length marker per cell, a reusable touched-cell
list, and reusable arrival scratch. Scratch is reserved from the update-queue
capacity; cell arrays still grow safely when arrivals exceed capacity. It does
not claim zero playback allocation. Its temporary appended population can be
larger than the final population before departures are compacted.

## Measurements

Both binaries: `-o:speed -microarch:native -debug`, assertions enabled.
CPU 2; terminal 200x50, dense 190x46 input/default canvas, seed 1, frame rate
zero, stdout `/dev/null`. Real CLI construction/playback/cleanup included;
CPU/RSS from `wait4`. Initial three-effect screen: three samples, minimum
0.5 seconds each. Full 35-effect suite: two samples, same minimum. No builds,
tests, captures, or profiles ran during timings. ASM was not rerun.

| Full-suite metric | Before | Batched |
| --- | ---: | ---: |
| Mean best wall | 33.109 ms | 36.651 ms |
| Mean child CPU | 32.989 ms | 36.560 ms |
| Mean per-effect peak RSS | 12,899 KiB | 13,272 KiB |

Aggregate wall regresses **10.70%**, CPU **10.83%**, RSS **2.89%**.
Geometric speedup is 0.959x. All 35 frame counts match.

The first screen reduced Middleout **25.9 → 7.2 ms** (recorded ASM is 8.4 ms),
and Expand **24.5 → 22.4 ms**, but increased Slide **20.8 → 27.9 ms**.
The full-suite run confirms the broader problem: Binarypath **160.4 → 215.0 ms**,
Swarm **104.7 → 116.3 ms**, Rings **87.2 → 97.2 ms**, and Scattered
**44.9 → 52.8 ms**. See [all 35 results](cell-batch-merge.tsv), including CPU,
RSS, and frame counts. Small changes near 0.1 ms are screening results, not
individually established regressions beyond noise.

## Profile and interpretation

A separate candidate Binarypath profile repeated 12 complete invocations:
`perf record -e cycles:u -F 999 --call-graph dwarf,8192`, CPU 2, zero lost samples.
Inline attribution includes **18.21% in cell_merge**, **6.36% in compose_frame**,
and **4.74% in cell_batch**. The arrival sort's `_smoothsort` has **5.37% self**.
These samples are observations of the candidate, not a before/after cycle
decomposition. They show the added cost is not solely arrival sorting.

Middleout benefits from eliminating hundreds of thousands of searches and
repeated shifts through crowded stacks. Universal batching adds a touched-cell
pass, survivor checks, arrival copying/merging, and sometimes arrival sorting
even for cases where the previous top/bottom paths were cheap. It is not a
global improvement in this form. Keep the experiment for further work; do not
replace the production path based on the Middleout result alone.

## Correctness and scope

- `odin check` and native build pass. Candidate source formatted with odinfmt.
- 222/222 deterministic capture cases preserve every reconstructed canvas
  frame, frame counts, prefix, and cleanup trailer. 195/222 streams are byte
  identical. The other 27 skip redundant row emission in Blackhole, Bubbles,
  Expand, Orbittingvolley, Scattered, and Spray.
- Tests: 81/85 pass, the same four allocation-test names fail as before:
  appearance_packet_survives_placement_changes,
  bounded_playback_reuses_build_storage,
  frame_composition_character_growth_is_amortized,
  rebuilt_output_storage_does_not_grow. Allocation counts changed; this is not
  a claim of equal allocator behavior.
- Full 35-effect timings exclude Matrix/Thunderstorm; their capture checks use
  virtual time. This is a rejected performance screen, not completed acceptance
  for a production replacement; no additional standalone parity/smoke run was
  performed.

Evidence directory contains `candidate/src`, `before`, `after`, `tests.log`,
`capture.py`, `capture-final.json`, `screen.log`, `bench.log`, `results.tsv`,
`summary.json`, and `binarypath.data`/`binarypath-self.txt`.
