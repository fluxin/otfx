# Performance decisions

The latest measurements and binary sizes are in the [release benchmark](release-benchmark.md).
The [integrated renderer report](intrusive-main.md) retains isolated change attribution.
Earlier effect work is in the [Spotlights follow-up](spotlights-prepared.md)
and [all-effect pattern audit](effect-patterns.md). The accepted compaction tradeoff
and earlier shared-motion work are in [shared motion](shared-motion.md).
Earlier production measurements are in [row renderer](row-renderer.md), with
[before/after](row-benchmark.tsv) and [ASM](row-asm-benchmark.tsv) tables. The
observations below are historical unless the current report explicitly retains
them; they are not an inventory of today's engine state.

## Retained

- Intrusive cell lists with lazy sorting replace per-cell arrays and compaction.
  Nodes retain published keys; queued changes contain only particle IDs.
  The user approved applying the measured aggregate win despite the disclosed
  Slide/Smoke/Overflow tradeoffs. [Current results](intrusive-main.md) separate
  integration, queue cleanup, and the frozen ASM comparison.

- Flat character/cell storage, direct four-byte color comparisons, one emission
  path, and color policy selected once per frame keep unchanged-cell work small.
- Paint only relevant characters. Reuse progress for equal path durations and
  skip completed motion or unchanged timeline samples. Keep final visible state
  and effect-owned completion timing intact.
- Reserve known playback storage at construction. This avoids arena growth and
  copies; it is an allocation-predictability choice, not a claimed CPU speedup.
- Keep the raster's `i32` empty sentinel: `Maybe(i32)` doubles cell storage on the
  measured target. Narrow enums help only when repeated enough and when padding
  actually shrinks the containing record. Pool capacity and motion tables matter
  more than low-multiplicity configuration enums.

## Rejected or deferred

| Experiment | Observation and decision |
|---|---|
| Standard-library priority queue per cell | [Indexed heap prototype](priority-queue-stack.md) deletes sorted insertion and compaction using `pq.push/remove` plus particle slot mappings. Two full sweeps show about 3% worse geometric time; Middleout/Expand improve but many effects regress. Timing variability is retained and disclosed. 756 captures match; preserve separately, do not promote. |
| Lazy sorting after winner departure | [Tracked top-slot prototype](lazy-top-stack.md) appends without insertion shifts and sorts only after losing the winner. Middleout 15.8→7.2 ms; 35-effect geometric time improves 1.5%, arithmetic mean worsens 0.36%. Binarypath, Scattered and Slide regress in both run orders. All 756 captures match; preserve isolated prototype, do not promote. |
| Bounded cell arrival sorting/merge | [Final preallocated-scratch control](bounded-cell-insert.md) improves Middleout 15.8→7.4 ms and removes the Blackhole regression, but the full mean is 0.7% worse while geometric time improves 0.8%. [Longer reversed-order repeats](bounded-cell-insert-recheck.md) confirm the mixed result. Storage-only controls reproduce several losses even without batching; preserve prototype, do not promote. |
| Runtime foreground/background palette and packed cell keys | Lookup/key maintenance made complete Bubbles/Laseretch runs roughly 20–40% slower and added about 1 MiB. Removed. This does not rule out IDs assigned during construction. |
| Wider string comparison | An alignment fault was corrected, but the wider comparison provided no useful speed advantage. Removed; retain string-content comparison. |
| Native scalar or paired SIMD rounding | Improved motion-heavy effects, but repeat checks retained Beams/Decrypt/Smoke regressions. Deferred in that earlier renderer. Revisited with the current row renderer and retained after full-suite validation; see the current report. The cause of the earlier regressions was not established. |
| Grouped Blackhole motion arrays | Full-run best wall rose from 89.5 to 94.2 ms with native rounding on both sides; a preconverted variant also lost. Removed because of runtime cost, not its extra storage. |
| Whole-animation/diff cache | Not pursued: frame-by-frame execution is already cheap enough to prefer lower memory use. Compact choreography tables remain appropriate. |

## Measurement rules

Use Python for visual accuracy and Rust for resource comparisons. To isolate an
optimization, compare frozen before/after Odin binaries with identical flags,
input, options, and seeds; preserve output and finite-effect frame counts. Run
sequentially, record CPU and peak RSS alongside wall time, and repeat suspicious
results with reversed or alternating order. Do not discard unfavorable samples
or retain a shared optimization with unresolved unrelated regressions.

For example, the latest completed-update guards reduced Scattered best wall from
115.4 to 78.8 ms and Orbittingvolley from 51.6 to 47.2 ms, with unchanged frames
and no added storage. That isolated comparison used three repeats, minimum
one-second samples, CPU 2, `-o:speed -debug`, and the README's dense fixture.
It is distinct from the current Rust comparison.

Matrix and Thunderstorm require separate paced CPU-duty measurements. One prior
Matrix comparison changed direction when run order reversed; it established
neither a stable paced saving nor a regression. Unpaced elapsed time is bounded
by their duration gates and must not enter the finite-effect throughput average.
