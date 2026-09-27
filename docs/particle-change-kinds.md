# Particle change kinds

The existing deduplicated particle queue now distinguishes placement changes
(position, visibility, layer) from content changes (glyph, appearance). Both
bits fit in the existing `Particle_Flags` byte; `Particle_Update`, particle
storage sizes, the effect-facing API, and ordered cell removal are unchanged.

Content-only entries skip removal processing and reuse their saved cell during
publication. They dirty it only if the particle is its final winner. Placement
entries retain remove-before-insert processing, which dirties old/new cells when
ownership changes. A placement round trip with no content edit no longer forces
a patch. Both change kinds accumulate on one queue entry and clear when drained.

This reduces work per queued update, not the number of legitimate updates.
A diagnostic of the first flag implementation counted:

| Effect | Placement updates (including combined) | Content-only updates | Patched cells before/after |
| --- | ---: | ---: | ---: |
| Colorshift | 8,740 | 1,855,039 | 1,862,123 / 1,862,123 |
| Swarm | 1,208,483 | 272,371 | 1,320,787 / 1,320,787 |

Instrumentation was separate from production timing. Its extra classification
loop makes its playback timings unsuitable as production results. Swarm still
has 1,480,854 queued updates: this change does not eliminate movement work.

## Final paired screen

| Metric | Frozen before | Change kinds |
| --- | ---: | ---: |
| 35-effect mean best wall | 45.826 ms | 44.969 ms |
| 35-effect mean wall | 45.931 ms | 45.051 ms |
| 35-effect mean child CPU | 45.749 ms | 44.869 ms |
| Mean per-effect peak RSS | 13,748 KiB | 13,710 KiB |
| Middleout best wall | 28.0 ms | 27.6 ms |
| Swarm best wall | 126.7 ms | 127.9 ms |

Best wall improved 1.87%, CPU improved 1.92%, geometric wall speedup 1.0206x.
No effect regressed more than 2% in this screen; Swarm is 0.95% slower.
All 35 finite-effect frame counts match. This is a small aggregate improvement,
not a solution to the ASM gap. Full per-effect results, including smaller
regressions, are in [particle-change-kinds.tsv](particle-change-kinds.tsv).

An initial flag implementation slowed Middleout about 8% in two screens.
A production profile concentrated samples in the existing per-layer linear
search. Consolidating flag writes and grouping the placement branch removed
that regression in the targeted confirmation and final full-suite screen; this
does not establish a precise microarchitectural cause. Ordered removal stayed
unchanged. Sorted layer IDs, binary search, and a last-entry pop shortcut were
discussed but are not implemented in this experiment.

Both binaries use `-o:speed -microarch:native -debug`, CPU 2, seed 1,
terminal 200x50, input 190x46, frame rate zero, stdout `/dev/null`. Full real
process lifetimes include build/setup. Two batched samples per effect, minimum
0.3 seconds per sample; no compilation, tests, or profiling overlapped timings.
ASM was not rerun. The baseline includes the prior action-batch prototype and
fixed packet copies, including the subsequent bulk setter API move.

Matrix and Thunderstorm used integer one-second configured duration diagnostics
and are excluded from the 35-effect aggregate. Matrix frame counts were
5,583/5,439; Thunderstorm 5,174/5,174. These wall-clock counts are not normalized
throughput. The first screen stopped at an invalid fractional Matrix duration;
its remaining finite effects were measured separately. The final screen above
ran the full harness successfully with valid durations.

## Validation and artifacts

- `odin check src` and native optimized/debug build pass.
- 222/222 exact before/after capture pairs: all 37 effects across plain,
  no-color, SGR always/dynamic, xterm/Unicode, and clipped fixtures.
- All 37 effects pass the four-frame smoke matrix.
- 71 unit tests: 67 pass; the same four allocation tests fail in the frozen
  before source (66/70). No allocation assertion was weakened.
- New coverage checks covered content, final winners after departures, both
  orders of combined edits, and offscreen content becoming visible. Existing
  placement-round-trip coverage now requires no redundant output.

Production delta: three engine files, 39 lines added / 30 removed (net +9).
Tests are in `tests/particle_updates.odin`. No new queues, allocations, per-cell
fields, or per-particle array-slot bookkeeping were introduced. Temporary
allocator lifetime is unchanged.

Artifacts: `/tmp/otfx-change-kinds-20260926`; frozen `before`, initial `after`,
final `refined`, source snapshots, profiles, captures, validation logs, and full
benchmark TSVs. Root `./otfx` was not replaced. No commits were made and earlier
work-in-progress remains intact.

```sh
BENCH_MIN_SECONDS=0.3 BENCH_MATRIX_RAIN_TIME=1 BENCH_STORM_TIME=1 \
  taskset -c 2 /tmp/otfx-change-kinds-20260926/bench-refined 2
```

The harness labels `rust`/`odin` mean before/after Odin binaries in this screen.

- Before SHA-256: `87896ad3e081ceb1443e3980f6f0d04d322245acf4fd93af334a88370cf209c3`
- Final SHA-256: `44b793053ac36a3bf1b31d8c4ffaee7026d527f32b1014c89c5c96e579b1d189`
