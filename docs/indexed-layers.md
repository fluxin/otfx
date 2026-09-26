# Directly indexed cell layers

Cells now store `layers: [dynamic][dynamic]Particle_Id`. The layer number is the
outer array index; the inner array contains only particle IDs. `Cell_Layer`, its
stored tag, matching-layer searches, and empty-bucket retagging are removed.

The experiment changes the layer contract to nonnegative indices. All shipped
effects use layers 0–3. Callers should use small, dense indices because each cell
retains array headers through its highest used layer. Negative indices are
rejected by both layer setters and insertion.

Two variants were preserved and measured:

- **Indexed, unordered:** one `cell_slot: int` records the ID's position in its
  layer array. Removal swaps in the last ID and repairs that ID's slot. The old
  layer is passed by the setter, so no per-particle bucket tag is needed.
- **Indexed, ordered removal (current working tree):** no `cell_slot`. Insertion
  appends IDs. Removal finds the ID with `slice.linear_search` and calls Odin's
  `ordered_remove`. There is no binary search, comparator callback, or sorted
  insertion. This preserves insertion order within each layer, at the cost of
  locating an ID and shifting the following IDs during removal.

Both variants retain the cached top particle. After removing the winner, they
walk layer indices backward to the first nonempty array and select its maximum
particle ID. The existing `(layer, particle_id)` priority is preserved: simply
popping the last appended ID would change overlap behavior on re-entry.

The renderer file shrank from 189 lines (tagged buckets) to 160 (indexed unordered)
and 158 (indexed ordered removal). The ordered variant also removes the final
per-particle membership index.

## Validation

Both indexed variants preserve all 222 exact captures (37 effects × six fixtures)
and pass source, tool, and instrumented phase checks. The ordered variant's
normal and instrumented test suites pass 54/58 tests. The same four pre-existing
allocation test names fail; allocation behavior has not been declared fixed.

The previous negative-layer tests now use nonnegative ranges with the same
relative ordering. Two new tests verify rejection through the individual and
combined setters. The independent full-paint oracle still covers clipping,
growth, equal/different layers, visibility, movement, and layer changes. Reverse
re-entry tests preserve the highest-ID winner despite insertion order.

The old test that retagged one empty bucket across layers -64…64 no longer fits
the indexed layout. Its replacement warms indices 0…128, then revisits them in
reverse and requires no additional allocations. All four pre-existing allocation
gate assertions remain intact. First visits to additional layer indices can
allocate; for example, the appearance/placement test's last reported allocation
counts change from expected 142/got 144 to expected 262/got 288, and bounded
playback from expected 76/got 706 to expected 76/got 901.

Parity against non-ASM Rust: 13 frame-count matches, 24 diagnostic differences,
zero failures.

## Measurement protocol

All CLI binaries use `-o:speed -microarch:native -debug`. CPU affinity is 2.
Each full 35-effect run uses seed 1, a 190×46 input, 200×50 terminal, unpaced
output to `/dev/null`, and three samples with a minimum 0.3 s batch duration.
CPU is wait4 child user+system; per-effect RSS is the maximum observed child RSS.
The aggregate wall metric is the unweighted mean of per-effect best wall times.
All harness labels refer to Odin binaries, not Rust or ASM. ASM was not rerun.

Artifacts in `/tmp/otfx-indexed-layers-20260926/` preserve the original tagged
renderer (`before` and `before-src`), indexed unordered (`unordered` and
`unordered-src`), indexed-with-bucket intermediate (`with-bucket` and
`with-bucket-src`), current ordered binary (`after`), tests, captures, benchmarks,
and the scoped source/test/document diff. No changes were committed.

## Recorded results

| Variant | 35-effect mean best wall | Mean child CPU | Mean per-effect peak RSS |
|---|---:|---:|---:|
| Tagged baseline | 47.6 ms | 47.8 ms | 14.8 MiB |
| Indexed unordered | 46.2 ms | 46.2 ms | 12.0 MiB |
| Indexed ordered removal | 47.4 ms | 47.4 ms | 12.0 MiB |

The unordered-to-ordered comparison is paired; all 35 frame counts match.
Its geometric speedup is 0.97x. Reverse-order five-sample checks (minimum 1 s)
confirm crowded-cell regressions: Blackhole 71.1 → 77.5 ms, Expand 30.0 → 36.0 ms,
and Middleout 18.7 → 30.2 ms (unordered → ordered). A separate reverse check
confirms Burn's tagged → unordered change, 37.2 → 39.6 ms. The ordered experiment
remains in the working tree for continued review; it was not reverted.

Full per-effect data: [unordered](indexed-layers-unordered-benchmark.tsv) and
[ordered](indexed-layers-ordered-benchmark.tsv). The ordered source, tests, and
docs were frozen under `ordered-src`, `ordered-tests`, and `ordered-docs` before
the subsequent appearance-ownership work.
