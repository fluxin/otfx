# Performance decisions

Current production measurements and reproduction commands live in the
[README](../README.md#performance) and [per-effect table](rust-benchmark.tsv).
The observations below explain design choices; historical experiment results
are not current production numbers.

## Retained

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
| Runtime foreground/background palette and packed cell keys | Lookup/key maintenance made complete Bubbles/Laseretch runs roughly 20–40% slower and added about 1 MiB. Removed. This does not rule out IDs assigned during construction. |
| Wider string comparison | An alignment fault was corrected, but the wider comparison provided no useful speed advantage. Removed; retain string-content comparison. |
| Native scalar or paired SIMD rounding | Improved motion-heavy effects, but repeat checks retained Beams/Decrypt/Smoke regressions. Deferred; the shared scalar helper remains. The cause of those regressions was not established. |
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
