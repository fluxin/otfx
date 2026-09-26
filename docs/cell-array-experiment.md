# Cell-owned particle arrays

The subsequent [fixed-cell experiment](fixed-cell-experiment.md) keeps this
ownership model and replaces packed row bytes with fixed slots. Measurements
below refer to the cell-array implementation before that subsequent change.
The later SoA, top/next, and layer-bucket trials below retain cell-owned
membership; the original representation and results remain as historical reference.

This is an uncommitted experiment retained for further work at the user's
request, including when it is slower. Do not revert it merely because a
performance or allocation gate fails. No acceptance claim is made.

## Original representation

Each `Render_Cell` owns `[dynamic]Particle_Id`, ordered by `(layer, particle_id)`.
The last ID is visible; an empty array means a blank cell. `max_layer` caches
the top layer for the append check. It remains an `int` to preserve the layer
API's range, including negative layers.

Insertion appends immediately when the incoming key belongs on top. Otherwise
`slice.binary_search_by` finds the insertion point and `inject_at` shifts the
suffix. Removal checks the last ID first, then uses the same search with
`ordered_remove`. A layer change searches using the old layer before reinsertion.
Movement locates the previous cell from the previous coordinate and visibility.

Particles no longer store `frame_cell`, `cell_previous`, or `cell_next`. Cells
no longer store a separate winner or linked-list head, and there is no winner
rescan. The initial-admission count, setters, row encoding, visual storage,
and temporary allocator lifetime are unchanged.

`Engine.cells` owns one grid allocation. `Render_Row.cells` is only a slice into
that allocation, not another array of cells. Each cell's particle IDs have their
own backing storage in this prototype.

The engine source grows from 2,520 to 2,535 lines. Removing particle links has
not yet produced a net source reduction: ordered insertion, removal, and the
search comparator replace those operations.

## Allocation finding

Odin's `inject_at` calls `resize`, which grows to the requested size when
capacity is exhausted. With a world arena, repeated exact-size growth retains
superseded storage until world destruction. The prototype explicitly reserves
geometric capacity before sorted insertion. Ordinary append also grows
geometrically.

This fixes repeated exact-size growth, but not playback allocations: cells
still allocate when first occupied or when their arrays exceed capacity. The
existing allocation assertions remain intact. This design has no fixed overlap
limit and does not silently drop particles from crowded cells.

## Validation

- `odin check src`, the instrumented source check, and checks of phase, parity,
  accuracy, and docs tools pass.
- 222 deterministic CLI captures are byte-identical to the frozen pre-trial
  binary, covering all 37 effects and six fixtures.
- 44 of 48 native tests pass. The four failures are allocation assertions in
  `appearance_packet_survives_placement_changes`,
  `bounded_playback_reuses_build_storage`,
  `frame_composition_character_growth_is_amortized`, and
  `rebuilt_output_storage_does_not_grow`.
- The frozen linked-list source passes all 48 tests with the same native flags.
- No test expectations were relaxed. Test/tool changes only replace direct
  winner-field access with `cell_owner`.

## Current result

Across all 35 finite effects, mean best wall time is **48.2 to 53.3 ms**
(about 11% slower), mean child CPU is **48.0 to 53.2 ms**, and mean peak child
RSS is **11.1 to 11.9 MiB**. Geometric wall speedup is **0.91x**. All measured
frame counts match. These results are against the linked-list baseline.

| Effect | Linked list, ms | Cell arrays, ms | Change |
|---|---:|---:|---:|
| Middleout | 16.0 | 39.5 | +146.9% |
| Expand | 29.9 | 40.3 | +34.8% |
| Unstable | 62.2 | 75.6 | +21.5% |
| Binarypath | 205.1 | 243.7 | +18.8% |
| Laseretch | 62.7 | 64.2 | +2.4% |
| Blackhole | 99.2 | 92.6 | -6.7% |

The full TSV includes every effect, not just these diagnostic cases. Small
differences have not been isolated from noise with longer reversed-order runs.
The aggregate and the large regressions do not meet the no-slowdown objective.

Before geometric reservation, `inject_at` exact growth measured 55.0 ms mean
wall and 22.0 MiB mean peak RSS; Middleout alone reached 115,428 KiB peak RSS.
With geometric growth, Middleout peaks at 11,544 KiB. That capacity correction
does not eliminate the remaining searches, ordered shifts, or playback growth.
No profile yet apportions their individual costs, so those are next diagnostic
targets rather than measured phase percentages.

## Measurement protocol

The baseline is the uncommitted linked-list implementation immediately before
this trial, not the earlier committed renderer and not a new ASM build. Both
binaries use `-o:speed -microarch:native -debug` with normal bounds checks.
The 35 finite effects run on CPU 2 with seed 1, frame rate 0, terminal 200x50,
input 190x46, and `/dev/null` output. Each side uses three samples of at least
0.3 seconds. CPU comes from `wait4`; RSS is peak child RSS. Compilation and
tests do not overlap the final measured run.

The harness calls its columns `rust` and `odin`; here they mean the frozen
linked-list Odin binary and the cell-array Odin binary. Full per-effect results
are in [cell-array-benchmark.tsv](cell-array-benchmark.tsv).

Binaries, frozen source snapshots, raw logs, captures, and the trial-only
`cell-arrays.patch` are in `/tmp/otfx-cell-arrays-20260926`. This experiment does
not refresh the ttfx ASM oracle.

## SoA follow-up

The sorted-SoA trial stores `#soa[dynamic]Cell_Particle`, where each entry has
`id: Particle_Id` and `layer: int`. Ordering remains ascending `(layer, id)`.
The top and immediately lower occupant are the last two entries; revealing the
lower occupant requires no search. A separate cached `max_layer` is gone.

Binary-search comparisons now read only the cell's two columns, without
following IDs into `Engine.particles.layer`. Odin's slice search does not accept
SoA slices, so a small local lower-bound search replaces the callback and its
engine-bearing key. Odin's built-in `append`, `inject_at`, and `ordered_remove`
maintain both columns. Geometric reservation remains. The particle retains its
requested layer for hidden/clipped state; the cell stores its published key,
which is removed with the old layer before reinsertion after a setter change.

`Render_Cell` remains **48 bytes** on this target. Occupant payload doubles from
**8 to 16 bytes** because the layer is now local. Engine source grows from
2,430 to 2,440 lines. This removes indirect ordering lookups and the maximum
cache; it does not remove ordered shifting or playback allocations.

The frozen baseline for this stage is the counted-row, fixed-slot renderer,
not the linked-list baseline above. With the same 35-effect native/debug protocol,
mean best wall time is **48.5 to 50.2 ms**, mean child CPU **48.8 to 50.2 ms**,
and average peak RSS **11.8 to 12.6 MiB**. Geometric speedup is **0.97x**.
All frame counts match. [All 35 results](cell-soa-benchmark.tsv) include
Middleout **40.1 to 50.0 ms (+24.7%)**, Expand **39.8 to 43.3 ms (+8.8%)**,
Blackhole **82.9 to 90.1 ms (+8.7%)**, and Fireworks **130.4 to 138.0 ms (+5.8%)**.
This does not meet the no-slowdown objective; the experiment remains for review.

Five-sample reversed-order checks with one-second minimum samples reproduce
the three largest percentage regressions: Blackhole **82.8 to 89.9 ms**,
Expand **39.6 to 43.2 ms**, and Middleout **40.1 to 49.9 ms** (before to after).
Other per-effect differences have not received this longer noise check.

All **222 exact CLI captures** match. Source and instrumented phase checks pass;
parity reports zero failures (13 exact frame-count matches, 24 diagnostic
differences). Native and instrumented test runs both pass 48 of 52 tests, with
the same four existing allocation failures. No assertions were weakened or
tests removed. Frozen source, binaries, full benchmark/capture logs, and the
scoped `cell-soa.patch` are under `/tmp/otfx-cell-soa-20260926`. Nothing was
reverted or committed, and no new ttfx ASM comparison is claimed.

## Top and next links within each cell

The linked trial retains the SoA and adds a `next: int` column. `Render_Cell.top`
heads a descending `(layer, id)` chain, and `free` heads reusable vacant slots.
Both chains use one-based slot indices and zero as the end; free slots reuse the
same `next` column. Insert reuses a slot or appends, then reconnects links.
Remove finds the ID, bypasses the slot, and returns it to the free chain. Top
removal immediately reveals the linked lower occupant. Particle IDs are not
zeroed: zero is a valid ID, and membership is determined by the live chain.

This deletes binary search, ordered shifting, geometric insertion reservations,
and the particle setter's old-layer snapshot. Only ordinary append grows storage;
insertion takes pointers to columns after that possible relocation. Engine source
shrinks from **2,440 to 2,432 lines**. Cell headers grow **48 to 72 bytes**, and
occupant payload **16 to 24 bytes** on this target.

Against the frozen sorted-SoA binary, the full 35-effect screen measures mean
best wall **50.2 to 57.0 ms (+13.5%)**, mean child CPU **50.3 to 57.0 ms**, and
average peak RSS **12.7 to 13.8 MiB**. Geometric speedup is **0.93x**. All frame
counts match. [Every effect is reported](cell-links-benchmark.tsv), including
Blackhole **89.8 to 188.5 ms**, Middleout **50.0 to 143.7 ms**, Expand **43.2 to
57.4 ms**, and Fireworks **137.6 to 170.4 ms**. Binarypath **231.8 to 225.7 ms**
and Swarm **162.8 to 158.0 ms** improve in this screen. Small differences have
not had longer reversed-order noise checks. The no-slowdown objective is not met.

A separate instrumented diagnostic uses identical input, seed, terminal size,
virtual clock, CPU affinity, and print mode. It records **108,295,745** chain
visits for Middleout and **71,217,361** for Blackhole, versus **6,170,347** and
**2,589,859** search probes in sorted SoA. Counter coverage differs at the fast
path: chain visits include the head, while the old counters exclude top checks.
Middleout's instrumented update time grows **50.3 to 155.0 ms**, Blackhole's
**82.2 to 190.3 ms**; composition and emission change little. Update includes
engine setters, not just effect math. This points to finding/reconnecting buried
occupants as the cost replacing shifts. These instrumented timings are diagnostic,
not the uninstrumented benchmark results above.

All **222 captures are byte-identical** to sorted SoA. Both ordinary and
instrumented test runs pass **49/53**, with the same four existing allocation
failures. A new regression exercises removal/re-entry, layer changes, emptying
and repopulating a crowded cell, lower-occupant visibility, and bounded slot
reuse. Source and instrumented phase checks pass; parity reports zero failures.
The scoped diff, frozen before sources/binary, candidate, tests, captures,
benchmark log, and phase diagnostic are in `/tmp/otfx-cell-links-20260926`.
No changes were reverted or committed; both representations remain preserved
for review. The linked version is now frozen beside the later bucket trial.

## Unordered layer buckets with a cached winner

The current trial stores `#soa[dynamic]Cell_Layer` on each cell, with a layer-value
column and a column of dense particle-ID arrays. `Render_Cell.top` caches the
winning ID. Each particle stores a renderer-owned `Cell_Slot` with its bucket
and position in that bucket. Removal accesses that slot directly, swaps in the
last ID, repairs the moved particle's slot, and clears the removed slot lookup.
There is no occupant-chain traversal, ordered shift, or free list.

Insert finds the matching layer and appends. It reuses an empty bucket for a new
layer value before allocating another bucket. Arrival order does not determine
visibility: the cached winner is compared by `(layer, particle_id)`. Only removal
of that winner rescans IDs, and only in the highest occupied layer. Layer values
remain signed native integers; negative values and later changes are preserved.
The SoA is now the layer table; occupant IDs within each bucket are one dense
column. Cell headers are **56 bytes**, layer records **48 bytes**, and each
particle's slot lookup adds **16 bytes**. Engine source is **2,448 lines**, up
16 from the linked trial. This trades links and ordered maintenance for a
lookup and bucket storage; it is not a net line-count reduction.

The matched native/debug 35-effect screen measures mean best wall **57.1 to
49.9 ms (-12.6%)**, mean child CPU **57.2 to 49.8 ms**, and average peak RSS
**13.8 to 15.5 MiB**. Geometric speedup is **1.10x**; all frame counts match.
The baseline is the frozen linked-SoA trial, not ttfx ASM or the fastest earlier
renderer. [All 35 effects](layer-buckets-benchmark.tsv) include:

| Effect | Linked slots, ms | Layer buckets, ms |
|---|---:|---:|
| Middleout | 143.6 | 19.0 |
| Blackhole | 188.6 | 79.9 |
| Expand | 57.6 | 34.6 |
| Fireworks | 171.0 | 128.7 |
| Binarypath | 227.8 | 256.0 |
| Slide | 29.7 | 33.3 |
| Laseretch | 55.7 | 58.6 |
| Errorcorrect | 15.7 | 16.9 |

Five-sample reversed-order checks with one-second minimum samples reproduce
Binarypath **228.8 to 255.7 ms**, Slide **29.8 to 33.4 ms**, and Laseretch
**55.8 to 58.8 ms** (linked to buckets). Other per-effect differences have not
had this longer check. Aggregate improvement does not meet the requirement
that no individual effect regress beyond noise.

Against the previously recorded [ttfx ASM baseline](dirty-rows-asm-benchmark.tsv),
the arithmetic mean is **49.9 versus 54.7 ms**, about **8.8% less time** for the
bucket version. The per-effect geometric comparison instead puts buckets about
**2.5% slower**. ASM was not rerun for this trial, and frame counts differ in
21 of 35 effects; this is a comparison of recorded complete CLI workloads,
not equivalent per-frame simulations or a fresh paired benchmark.

An instrumented diagnostic records **137,838** winner-replacement candidates
for Middleout and **3,410,906** for Blackhole, compared with **108,295,745** and
**71,217,361** chain visits in the linked trial. The new counter excludes direct
slot access and bucket lookup, so these are work counts for different paths,
not identical per-operation counters. Middleout's instrumented update time is
**17.3 ms**, Blackhole's **73.0 ms**; frame counts and emitted byte counts match
the earlier diagnostic. These timings include instrumentation and are separate
from the full CLI results above.

All **222 captures are byte-identical** to the linked baseline. Normal and
instrumented runs both pass **50/54 tests**, with the four existing allocation
tests still failing. Allocation counts are higher than the linked baseline:
in the reported bounded-playback case, **414 becomes 733** allocations against
an expected 103. New buckets and their ID storage require playback allocation;
this remains an open gate. The slot-reuse test now checks swap-lookup repairs
and stable bucket capacity after warming the exercised layer transitions. A new
test verifies 129 layer values on one occupied cell with no allocation after its
first frame. No existing allocation assertions were relaxed. Source/phase checks
and parity pass (zero failures, with 24 diagnostic frame-count differences).

The first bucket version, before empty-bucket reuse, is preserved as `after-first`
with its source and tests; it measured **57.1 to 49.2 ms** in its matched screen.
The final source, frozen linked baseline, candidates, complete logs, and scoped
`layer-buckets.patch` are under `/tmp/otfx-layer-buckets-20260926`. Nothing was
committed or reverted. The bucket implementation remains active for review.
