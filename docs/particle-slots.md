# Particle-owned cell and slot experiment

Historical experiment, preserved in frozen source/binary artifacts. It passes
output checks but fails the performance acceptance gate. The working tree now
uses the [flat sorted cell stack](cell-stack.md); the results below describe
the earlier reverse-slot implementation.

`Particle.cell` and `Particle.cell_slot` identify published renderer membership.
Effects still request position, visibility, layer, glyph, and appearance through
the same API. New/hidden/offscreen particles have cell/slot `-1`. The renderer
sets both on insertion and clears both on removal.

Removal directly indexes the old cell's layer, asserts the slot contains the
expected ID, and uses `ordered_remove`. It then repairs the slot of every
shifted occupant. No hash map, raw pointer, sorted insertion, or swap removal
was added. The stored cell replaces `Particle_Update.previous_cell`; the queue
still snapshots the old layer before requested layer changes. Content-only
updates use the particle's published cell.

On this 64-bit target, two `int` columns add 16 bytes per particle; queue entries
shrink from 24 to 16 bytes. No additional allocation sites or frame scratch
buffers were added. Production delta is 20 lines added / 16 removed, net +4,
across `particle.odin` and `render.odin`.

## Full-binary results

| Metric | Before (change flags) | Cell/slot index |
| --- | ---: | ---: |
| 35-effect mean best wall | 45.026 ms | 45.297 ms |
| 35-effect mean wall | 45.277 ms | 45.423 ms |
| 35-effect mean child CPU | 45.097 ms | 45.240 ms |
| Mean per-effect peak RSS | 13,678 KiB | 13,660 KiB |
| Middleout best wall | 27.6 ms | 39.8 ms |
| Fireworks best wall | 82.5 ms | 92.0 ms |
| Expand best wall | 27.5 ms | 29.8 ms |
| Swarm best wall | 127.6 ms | 124.4 ms |
| Colorshift best wall | 30.2 ms | 28.8 ms |
| Waves best wall | 32.8 ms | 30.2 ms |

Aggregate best wall is 0.60% slower, CPU 0.32% slower: approximately flat, with
material individual regressions. Geometric wall speedup is 0.9981x. Regressions
above 2%: Middleout +44.2%, Fireworks +11.5%, Expand +8.4%, Crumble +3.0%, Slide
+2.1%. A separate two-sample targeted run reproduced these regressions and the
Swarm improvement. Full per-effect wall/CPU/RSS/frame data is in
[particle-slots.tsv](particle-slots.tsv).

Against unchanged cached ASM `c2be6411` (mean 30.8 ms; Swarm 95.3 ms), the
experiment remains about 47% slower overall and 31% slower on Swarm. ASM was
not fetched/rebuilt/rerun here. These are whole-effect durations, not identical
frame workloads: Swarm emits 4,312 Odin frames versus the cached ASM's 5,041.

## Middleout profile and workload

Production profiling used `perf record -e cycles:u -F 999` over 60 complete
Middleout runs per frozen binary, pinned to CPU 2 with the benchmark input.
The new slot-repair loop (`render.odin:56`) accounted for 49.41% of sampled
cycles. In the baseline, the linear-search loop accounted for 23.83%.
These are sampled attribution percentages, not isolated instruction costs.

Separate instrumented source copies counted membership operations:

| Effect | Search comparisons eliminated | Shifted entries requiring slot repair | Removals |
| --- | ---: | ---: | ---: |
| Middleout | 29,926,912 | 65,517,674 | 417,818 |
| Fireworks | 1,203,781 | 43,356,700 | 769,147 |
| Swarm | 1,622,075 | 1,164,414 | 1,097,865 |

The number of ordered shifts is unchanged. The reverse index adds a slot-column
write for each shifted entry. Middleout's instrumented effect-update time was
10.28 -> 10.11 ms, composition 15.40 -> 29.72 ms, and patch/emission 0.87 ->
0.92 ms. These diagnostic times exclude setup and contain instrumentation;
use the production table above for performance comparisons. Dirty cells,
output bytes, frame counts, and ownership-resolution visits were unchanged.

Middleout itself starts all particles at the canvas center, expands them to a
central row/column, then expands them to their original coordinates. This
matches the Python reference's two-phase construction. During the first phase,
particles sharing an input column (vertical expansion) or row (horizontal)
follow identical paths, but the effect calculates easing/coordinates per active
particle. Settled motion skips already exist; color fading continues as needed.
Sharing those path calculations is a separate effect-side opportunity. It does
not explain the reverse-index regression: the added cost is in slot maintenance.
No effect code was changed in this experiment.

## Validation and reproduction

- `odin check src`, formatting, and native optimized/debug builds pass.
- 222/222 exact captures across all 37 effects and six fixtures.
- 37/37 four-frame smoke checks; parity: 13 match, 24 existing diagnostic
  differences, zero failures.
- 71 unit tests: 67 pass; the same four pre-existing allocation failures.
- Reverse-index invariants checked in both directions across the existing
  full-paint oracle's varied widths, clipping, overlapping layers, and particle
  growth, plus repeated crowded-cell hide/show/layer transitions.
- Requested changes preserve published cell/slot until rendering.
- All 35 finite-effect frame counts match. Matrix/Thunderstorm one-second
  duration diagnostics are excluded from the aggregate; their before/after
  frame counts are 5,583/5,465 and 5,174/5,174, respectively.

Both binaries: `-o:speed -microarch:native -debug`, CPU 2, seed 1, terminal
200x50, input 190x46, frame rate zero, stdout `/dev/null`. Two samples, each
batched to at least 0.3 seconds. No compilation, tests, or profiling overlapped
benchmark timing. No ASM rerun. Root `./otfx` was not replaced; no commits made.

```sh
BENCH_MIN_SECONDS=0.3 BENCH_MATRIX_RAIN_TIME=1 BENCH_STORM_TIME=1 \
  taskset -c 2 /tmp/otfx-particle-slots-20260926/bench 2
```

Harness `rust`/`odin` labels refer to frozen before/after Odin binaries.
Artifacts: `/tmp/otfx-particle-slots-20260926`, including source snapshots,
`engine.diff`, captures, `full.tsv`, `recheck.log`, `before.data`, `after.data`,
line profiles, and isolated instrumented source/counter runs. The baseline
source was verified against the previously validated change-flags binary.

- Before SHA-256: `44b793053ac36a3bf1b31d8c4ffaee7026d527f32b1014c89c5c96e579b1d189`
- After SHA-256: `f37ea4b8c33e10f8afe4bd13f5fd41a32b4d9805e34a1644e3a7a3a5bbdcaa1d`
