# One shift and bounded cell sorting

2026-09-27. Isolated experiment against checkpoint `0f71b549`; production source
is unchanged. All candidate sources and binaries are preserved under
`/tmp/otfx-range-insert-20260927`. This implements the proposed global renderer
change, not an effect-specific Middleout shortcut.

A [longer reversed-order recheck](bounded-cell-insert-recheck.md) repeats the mixed
aggregate result and tests storage-only controls. It supersedes the short screen
for judging which small regressions repeat.

## Latest result: bounded merge with preallocated scratch

The final `preallocated/` variant preserves the old overlap's ordering. It sorts
only incoming keys (guarded by `slice.is_sorted`), shifts the suffix once and
merges backward only within the bounded interval. A single arrival needs one
binary search and one suffix shift. A cell with one occupant handles a covered
arrival immediately, without gathering; direct top appends/pops remain intact.
The per-cell fields are reordered to reduce the candidate cell size from 80 to
72 bytes (production is 64 bytes).

One engine-owned scratch buffer is sized alongside particle/update capacity in
`input.odin` and `particle.odin`, using nonzero resize only when population
capacity grows. Rendering takes `cell_arrivals[:arrivals]`; it neither allocates
nor resizes scratch. Effects adding particles later grow scratch through the
same population path. Scratch costs eight bytes per particle capacity, not one
buffer per cell. Cell-stack growth itself is unchanged in scope and may still
allocate; this is not an allocation-free engine claim.

Full 35-effect screen, two samples of at least 0.3 seconds:

| Metric | Before | Final candidate |
|---|---:|---:|
| Mean best wall, ms | 30.280 | 30.480 |
| Mean CPU, ms | 30.174 | 30.351 |
| Mean peak RSS, KiB | 13249 | 13332 |

Geometric candidate/before time is **0.992** (0.8% better); arithmetic mean wall
is **0.7% worse**. Neither establishes a broad aggregate improvement at this
sampling depth. All frame counts match. The prototype is preserved for review,
but **not promoted** because the gains coexist with unrelated regressions.

| Effect | Before ms | Final candidate ms |
|---|---:|---:|
| Middleout | 15.8 | 7.4 |
| Blackhole | 55.5 | 53.3 |
| Expand | 20.4 | 19.4 |
| Slide | 17.3 | 16.7 |
| Binarypath | 162.7 | 167.8 |
| Rings | 79.1 | 81.9 |
| Scattered | 30.8 | 32.3 |
| Swarm | 107.1 | 109.3 |

Middleout is faster than the recent separate 8.4 ms ASM measurement, which was
not refreshed during this experiment. That single-effect result is not a global
claim. All per-effect regressions, including small screening differences, are
in the TSV's `preallocated-full.log` rows.

The native `is_sorted` control alone was effectively flat: manual/native guard
Middleout 12.0/12.1 ms, Blackhole 65.4/65.5, Binarypath 172.6/171.6, Slide
18.5/18.4. It made the check simpler but did not remove additional sorts. The
bounded merge, rather than the guard, removed the Blackhole regression:
55.4/54.7 ms in its first screen. Simple-cell handling subsequently helped Slide.

The final variant passes `odin check`, optimized/debug build, and **756/756
byte-identical captures**. Its tests also finish **82/86**, with the same four
allocation-failure names and changed allocation counts. No fixes to those tests
are claimed. Earlier controls and the final sources are all retained.

Final binary SHA256:
`289ff667f1d776540c8566fed1c1a2ed4bece3f933dda7616d5c4cb52d17d15c`.
Final benchmark: `bench-preallocated`, the same complete effect list below,
`BENCH_MIN_SECONDS=0.3`, two repeats, comparing `before` with
`preallocated/after`. `preallocated.patch` contains all four source-file changes.

## Algorithm

Keep direct ordered appends and top pops when no arrivals are pending. On the
first overlapping arrival, append it and subsequent arrivals to an unsorted
suffix and queue the cell once. Store only the suffix count on the cell; reuse
the existing affected-cell list and one shared arrival scratch buffer.

After draining updates, compact departed keys from the original sorted prefix.
Find the incoming minimum and maximum `(layer, particle ID)` keys, binary-search
both bounds in the surviving prefix, shift the suffix once, place the incoming
batch, and sort only the overlapping interval. Already ordered arrivals fitting
in a gap need no sort. Departure-only cells retain their compaction path. The
final winner still uses maximum layer/ID and only final cells are emitted.

The first variant uses `slice.sort` (Odin's generic smoothsort). The second uses
native typed `sort.quick_sort` over the same interval. A third replaces the
manual ordered-arrival flag with `slice.is_sorted(affected)` before quicksort.
Odin's native sorted check scans backward and exits on the first inversion.
For unique keys, this changes how sortedness is checked, not which ranges need
sorting: a nonempty overlap necessarily contains an existing key above an
incoming key that was placed after it.

## Initial sort-only controls

Whole CLI initialization, build, playback and cleanup, output `/dev/null`.
Both sides use `-o:speed -microarch:native -debug`, assertions enabled and the
existing scoped bounds exclusions. CPU 2, seed 1, terminal 200x50, dense default
canvas 190x46, frame-rate zero. CPU and peak RSS are native `wait4` values.
No own build, capture, test or profiler ran concurrently with timing.
Matrix/Thunderstorm remain excluded from throughput means.

[Complete per-effect wall, CPU, RSS and frame results](bounded-cell-insert.tsv).
`full.log` is before versus smoothsort (two samples, minimum 0.3 seconds).
`quick-full.log` is before versus quicksort (two samples, minimum 0.2 seconds).
`quick-screen.log` repeats four effects with three 0.3-second samples.
`sorted-screen.log` compares quicksort's manual guard against native `is_sorted`,
with three 0.4-second samples; its before column is the quicksort candidate.

| Full 35-effect metric | Before / smoothsort | Before / quicksort |
|---|---:|---:|
| Mean best wall, ms | 30.420 / 34.723 | 30.271 / 31.869 |
| Mean CPU, ms | 30.346 / 34.623 | 30.174 / 31.754 |
| Mean peak RSS, KiB | 13159 / 13387 | 13089 / 13386 |
| Geometric candidate/before time | 1.107 | 1.039 |

Smoothsort regresses arithmetic mean wall **14.1%**. Quicksort reduces that
regression to **5.3%**, with a **3.9% geometric regression**. All frame counts
match. These screens establish no global win; small sub-millisecond differences
are not independently established regressions beyond noise.

| Effect | Before ms | Bounded quicksort ms |
|---|---:|---:|
| Middleout | 15.9 | 12.0 |
| Binarypath | 162.5 | 172.7 |
| Blackhole | 55.6 | 65.4 |
| Expand | 20.3 | 22.4 |
| Rings | 79.1 | 85.6 |
| Scattered | 30.8 | 33.9 |
| Slide | 17.3 | 18.5 |
| Swarm | 106.9 | 112.2 |

## Work counters and interpretation

Counters are from a separate diagnostic binary, not the timed binaries.
For Middleout, suffix shifts drop from the earlier measured 41,712,740 entries
to 61,949 entries. The candidate gathers 341,584 arrivals into 21,084 batches;
its overlap windows contain 182,445 old entries and it sorts 473,059 entries
across all calls (largest sorted window: 2,178).

Blackhole gathers 307,711 arrivals into 146,241 batches, shifts 391,019 entries,
and includes 1,550,830 old entries in overlap windows. It sorts 1,595,813 entries
in total, with a largest window of 6,658. A bounded key interval can still cover
much of a crowded cell. The candidate gives up the ordering already known for
those surviving entries, and adds gathering, scratch copying, boundary searches
and finalization for many small batches. This explains the algorithmic tradeoff;
these counters are not a measured cycle attribution for each added operation.

The older full-stack merge experiment reached 7.2 ms for Middleout but also lost
globally; see [that experiment](cell-batch-merge.md). These distinct experiments
are retained for review rather than promoted from a single-effect win.

## Correctness and retained artifacts

- Optimized/debug builds pass; the initial and native-guard variants pass `odin check`.
- Each variant passes 222 standard plus 534 option/seed/color captures: all 756
  are byte-identical to the frozen production binary.
- Initial candidate unit suite: 82/86 pass. The four failures have the same names
  as the previously known allocation failures; allocation counts change. This
  is not an allocation-free claim. The sort-only variants were capture-checked;
  their full unit suites were not rerun.
- No source promotion, deletion of the prototypes, or commit in this experiment.

Sources: `src/`, `quick/src/`, and `sorted/src/` inside the artifact directory.
`render.patch`, `quick-render.patch`, and `quick-engine.patch` provide reviewable
diffs. `instrument/src/` adds work counters only. Raw benchmark logs, capture
JSON/scripts, unit-test log, and the report generator are retained alongside them.

Frozen binary SHA256:

- Before: `80b04054f4ca71f123d874b69c0d7ebe52190fa9ba65f283348e2fef1bfac0a8`
- Smoothsort: `561e6fa0ab595d3784c6d18d21e20025321984d55903d7800a5993843c14af4d`
- Quicksort: `4ed4636072ac7a3a986e2d121d8480dee94ffed0ff2d6238ee7ee8d8cf2647fa`

The native harness is built with `REFERENCE_BENCH_BINARY` and
`OTFX_BENCH_BINARY` pointing to the specified frozen pair, then run as:

```sh
BENCH_MIN_SECONDS=0.2 taskset -c 2 /tmp/otfx-range-insert-20260927/bench-quick 2 \
  beams binarypath blackhole bouncyballs bubbles burn colorshift crumble \
  decrypt errorcorrect expand fireworks highlight laseretch middleout \
  orbittingvolley overflow pour print rain randomsequence rings scattered \
  slice slide smoke spotlights spray swarm sweep synthgrid unstable vhstape waves wipe
```
