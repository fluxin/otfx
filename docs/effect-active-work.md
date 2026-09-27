# Skip unchanged calculations and retire inactive work

Implemented 2026-09-26, uncommitted. This change follows the dependencies and
lifetimes in Odin's effects: compute only when inputs can change, retire work
after its last publication, and apply already-generated data without another
gather pass. No ASM algorithm was ported. Native easing, rounding, RNG order,
phase lengths, and the renderer's cell representation are retained.

## What can be skipped, and why

| Effect | Dependency/lifetime | Implementation |
| --- | --- | --- |
| Middleout | Every particle in a column shares the first horizontal motion; every particle in a row shares the second vertical motion. Horizontal expansion swaps these roles. | Two small axis arrays replace three per-particle motion arrays. Evaluate each occupied axis once per frame. Publish positions only when its rounded coordinate changes. |
| Unstable | Motion cannot change after arrival. Rumble colors change every ten ticks; reassembly colors every three. Final duration depends only on build-time motion lengths and initial colors. | Retire settled motion through stable active-index compaction, reactivate at reassembly, update gradients only at boundaries, and determine duration during build. Retain particles until both motion and color work finish. |
| Spotlights | Illumination depends on integer spotlight positions, radius, and the Expand color rule. | Advance motion/RNG/timing, then skip illumination when those inputs are unchanged. Force the initial illumination and Expand transition. In Expand all lights coincide, so calculate one distance. Dynamic foreground restoration needs no distance calculation. |
| Swarm | Cached frames are already selected while visiting active particles. | Apply each selected frame immediately through `set_particle(e, id, frame)`. Delete `load_ids`, `load_frames`, their allocations, and the second application pass. |
| Spray | Unlaunched and completed particles cannot change. Color steps change every twenty ticks and finish at age 140. | Append newly launched indices to an active list and compact it while updating. Record the overall end tick during activation instead of scanning all particles for termination. Preserve motion's arrival-boundary layer reset and the existing 160-tick color hold duration. |
| Scattered | Arrival publishes final position/color/layer; later frames cannot change them. Dynamic input colors are already installed during build. | Retire particles after that publication and iterate the remaining active list. Remove repeated dynamic input-color application. |

`set_particle` accepts either one `Sequence_Frame` or slices of IDs and frames.
Both use the same inline implementation, including change guards and queue
deduplication. The slice wrapper no longer temporarily enlarges the update
array to the particle count. Swarm's existing bounded frame generation remains;
this removes staging, not that earlier experiment.

Middleout still publishes particle positions after evaluating the small axis
arrays, and Spotlights still examines characters when illumination changes.
This is not a claim that every scan has disappeared. The new active lists are
effect-owned arrays, not another renderer bookkeeping layer or interpreter.

## Full-binary measurements

Paired native optimized/debug binaries, CPU 2, terminal 200x50, input 190x46,
seed 1, frame rate zero, stdout `/dev/null`. Two samples with at least 0.5 s
per batch. Only the six changed effects were benchmarked; unchanged effects
and ASM were not rerun. These are full-effect wall times including setup.

| Effect | Before ms | After ms | Reduction | Frames before/after |
| --- | ---: | ---: | ---: | ---: |
| Middleout | 30.2 | 22.3 | 26.2% | 235 / 235 |
| Swarm | 120.3 | 116.1 | 3.5% | 4,312 / 4,312 |
| Spray | 49.3 | 28.2 | 42.8% | 1,253 / 1,253 |
| Scattered | 54.0 | 52.3 | 3.1% | 420 / 420 |
| Unstable | 59.2 | 43.8 | 26.0% | 592 / 592 |
| Spotlights | 49.9 | 42.5 | 14.8% | 780 / 780 |

No measured effect regressed. Small improvements, especially Swarm and
Scattered, remain short-screen results rather than a statistical confidence
claim. [Per-effect wall, child CPU, peak RSS and frame counts](effect-active-work.tsv).
RSS is broadly similar; the TSV retains individual changes rather than
claiming every effect uses less memory. This is not a new full 35-effect mean
or a fresh ASM comparison.

Spray was remeasured after its last refinement retired color work at age 140
while retaining the effect's existing end tick. The other five were unchanged
from their six-effect screen and were not rebenchmarked.

## Where the time went

The diagnostic phase harness shows effect-update reductions, while renderer
candidate visits, patched cells, emitted bytes, and frame counts remain exact:

| Effect | Update before ms | Update after ms | Compose before/after ms |
| --- | ---: | ---: | ---: |
| Middleout | 10.09 | 2.32 | 17.80 / 18.04 |
| Swarm | 60.55 | 55.94 | 33.88 / 34.21 |
| Spray | 33.91 | 12.00 | 6.51 / 6.36 |
| Scattered | 30.11 | 28.59 | 13.05 / 13.03 |
| Unstable | 30.20 | 15.05 | 15.82 / 15.84 |
| Spotlights | 40.90 | 33.46 | 1.52 / 1.51 |

The engine's setter guards already filtered redundant submissions. This work
avoids calculating and submitting many of those values in the first place.
Middleout now spends most of its remaining time in composition; its effect
update is much smaller. Swarm still pays for active-frame generation and
publication, and Scattered still evaluates easing/gradients for live motion.

These phase values contain instrumentation overhead, including diagnostic
row scans outside the named phases; they are not production timing totals.
[Phase data](effect-active-work-phases.tsv), [baseline profile](effect-update-profile.md).

## Validation and saved evidence

- Formatting, `odin check src`, native optimized/debug builds pass.
- 78 tests: 74 pass, the same four pre-existing allocation tests fail.
  New boundary tests cover Unstable's color finish after fast motion and
  Spotlights' stationary-frame phase progression/dynamic restoration. The
  sequence test now mixes scalar and bulk publication through one queue.
- 222/222 standard byte-exact captures across 37 effects and six fixtures.
- 396/396 additional exact captures across all six changed effects: seeds,
  existing-color modes, speeds, easing, Middleout directions, spotlight count
  and falloff, swarm coordination/group sizes, spray positions and volumes.
- 37/37 smoke checks. Parity: 13 match, 24 existing diagnostic differences,
  zero failures.
- No commits; root executable unchanged. Production delta is 233 lines added,
  182 removed, net +51, including formatter realignment. This is not a net
  source-line deletion despite removing staging and redundant work.

Frozen binaries, before/final source snapshots, captures, tests, benchmarks,
phase data, and diffs are under `/tmp/otfx-effect-skips-20260926/`.
`before` is the flat-stack baseline. `active` is the six-effect benchmark
candidate; `final` includes only the subsequent Spray retirement refinement.
Earlier `after-two-effects` and `after` binaries preserve intermediate work.

```sh
BENCH_MIN_SECONDS=0.5 taskset -c 2 /tmp/otfx-effect-skips-20260926/bench-active 2 middleout swarm spray scattered unstable spotlights
BENCH_MIN_SECONDS=0.5 taskset -c 2 /tmp/otfx-effect-skips-20260926/bench-final 2 spray
```

The harness's `rust` label denotes the frozen Odin baseline in these screens.
