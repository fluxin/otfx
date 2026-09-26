# Effect build/next corrections — 2026-09-26

This applies the existing build/next contract to the three effects identified
in the [latest ASM review](latest-asm-profile.md). The renderer, appearance
API, SIMD rounding, and allocator are unchanged. No color-count limit was
introduced. No commits were made.

## Implementation

- **Expand:** build the eleven-step FG/BG color table per character; advance
  a stably compacted active-index list. Publish the arrival coordinate, final
  colors, and layer zero before retiring the particle. Total effect duration
  remains unchanged.
- **Fireworks:** build the eleven-color bloom table per shell, sixteen-step
  fall table per particle, and completion ages. Unlaunched shells occupy an
  untouched prefix of the index array; each reverse-order launch exposes the
  next contiguous prefix, and active entries compact in their existing order.
  Retire only after both motion and color finish. Launch RNG draws, delays,
  phases, and current layer behavior are preserved.
- **Swarm:** build the landing color tables and calculate each moving
  particle's easing factor once for both coordinates and color selection.
  Preserve its existing active list, planned interruptions, and dynamic
  color-clearing timing.

The tables store color pairs, not duplicate 43-byte encoded appearances.
Dynamic gradients target the original input colors; ordinary palettes start
from the current effect style. Those differ because input construction starts
the effect with a plain glyph while retaining original styling separately.
This distinction preserves dirty-row behavior in `existing-color-handling
always` mode as well as the rendered appearance.

The three production files changed by +152/-167 lines: net **15 fewer lines**.
Two regression tests check final publication before retirement and ensure later
ticks/shells do not revisit retired particles.

## Performance

Dense input/default canvas 190x46 in a 200x50 terminal; seed 1; frame rate 0;
stdout `/dev/null`; CPU 2; frozen before/after binaries built with
`-o:speed -microarch:native -debug`. Three batched samples per effect,
minimum 0.3 seconds. No build, test, or profiling job ran during measurement.

| Effect | Before best wall | After best wall | Reduction | Latest ASM reference |
| --- | ---: | ---: | ---: | ---: |
| Expand | 35.2 ms | 27.3 ms | 22.4% | 16.6 ms |
| Fireworks | 117.0 ms | 83.8 ms | 28.4% | 62.5 ms |
| Swarm | 149.7 ms | 142.6 ms | 4.7% | 95.3 ms |

ASM values reuse the earlier unchanged `c2be6411` binary's measurements under
the same flags/workload/affinity/sample settings. They are context, not a new
paired ASM run. All before/after frame counts match (302, 1,516, 4,312).

The 35 finite-effect results completed before the user requested narrower
benchmark scope. Their arithmetic mean best wall is **48.1 -> 46.7 ms
(-3.0%)**, mean wall **48.4 -> 47.0 ms**, and mean child CPU **48.2 -> 46.8
ms**. Mean per-effect peak RSS rounds to **13.2 MiB** for both builds; the
changed effects use additional palette storage. Full per-effect CPU/RSS,
frame counts, and wall results are in [the TSV](build-contracts-benchmark.tsv).
Spotlights, whose source is unchanged, was +2.1% in this screen; no repeat was
run to distinguish that small change from noise. No other effect exceeded
a 2% slowdown in the screen.

Matrix and Thunderstorm are excluded from the aggregate. Their configured
windows were one second; the queued sequence was interrupted during the
Thunderstorm diagnostic after all finite-effect rows had been recorded.
The repeated full ASM suite, size screens, and five-sample confirmation were
cancelled. For further effect-only work, measure changed effects and reuse
unchanged reference evidence; broaden only for shared-code changes or a
specific unresolved regression. No performance claims are made for new sizes
in this change.

## Validation

- `odin check src`, formatting of changed files, optimized build: pass.
- 222/222 standard exact before/after captures.
- 27/27 additional accepted option/edge captures; nine empty-input
  rejection stdout/exit outcomes unchanged.
- 62/66 unit tests pass, including both new retirement tests. The four
  original allocation-test failures remain; none was suppressed or weakened.
- Parity tool: 13 matches, 24 existing diagnostic differences, zero failures.

Phases and invariants were checked against the original Python Expand,
Fireworks, and Swarm implementations before editing. Exact captures establish
preservation of this Odin implementation, not new byte parity with another
engine.

## Reproduction

Artifacts and source snapshots: `/tmp/otfx-build-contracts-20260926`.

```sh
BENCH_MIN_SECONDS=0.3 taskset -c 2 \
  /tmp/otfx-build-contracts-20260926/bench 3 expand fireworks swarm
```

The harness labels reference/candidate as `rust`/`odin`; both binaries are
Odin in this before/after experiment. `effects.diff` is scoped to this change,
while `before-src` and `before-tests` preserve the incoming work.

SHA-256:

- Before: `f7d9d2b8ee42f7e6956323a8da09a34feb3b6bd7a3319b9100921592230c3229`
- After: `2cab52fdea20f46dbb353a9626a8c6d9dae00b73b379ba3eace19bd4bb334a3c`
