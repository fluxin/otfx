# Existing performance patterns across all effects

2026-09-26, uncommitted working tree. All 37 effects were reviewed. This pass
changes 23 effects, using the existing `group_values`, dense active lists,
phase-entry publication and held-sample guards. It adds no engine API,
renderer path, scheduler, animation cache or playback allocation. Earlier
Scattered, Fireworks and deferred-compaction changes remain intact.

## Measurements

[Before/after wall, CPU, RSS and frames](effect-patterns-benchmark.tsv) covers
all 21 changed finite effects. Their unweighted best-wall mean falls from
**34.448 to 31.167 ms**, a **9.5% reduction**; geometric speedup is **1.139x**.
Every measured finite effect improves or stays within noise. Errorcorrect,
Laseretch and Waves are effectively flat; their small differences are not
established speedups. Native frame counts are unchanged in every comparison.

| Effect | Before ms | After ms | Earlier ASM ms |
|---|---:|---:|---:|
| Rings | 91.3 | 79.7 | 104.0 |
| Binarypath | 170.2 | 162.1 | 183.4 |
| Blackhole | 63.4 | 55.5 | 54.9 |
| Unstable | 43.1 | 37.1 | 35.3 |
| Slice | 10.8 | 6.0 | 6.6 |
| Crumble | 46.3 | 41.8 | 49.0 |
| Orbittingvolley | 23.2 | 19.0 | 17.4 |
| Expand | 24.6 | 20.5 | 16.6 |
| Slide | 20.7 | 17.5 | 12.7 |
| Synthgrid | 10.7 | 8.4 | 5.1 |

## Fresh 35-effect ASM comparison

After the user reported the other timing agent had quieted down, a fresh
comparison ran all 35 finite effects against the frozen ASM binary, forcing
`TTFX_ASM=force`. [Complete chart, CPU, RSS and frame counts](effect-patterns-asm.tsv).
This supersedes the mixed earlier snapshot estimate.

| Unweighted mean | OTFX | ASM |
|---|---:|---:|
| Best wall per effect | 30.480 ms | 30.860 ms |
| Mean wall per effect | 30.520 ms | 30.926 ms |
| Mean child CPU | 30.374 ms | 30.757 ms |
| Peak RSS per effect | 12.727 MiB | 50.428 MiB |

OTFX's arithmetic best-wall mean is **1.2% lower**, roughly parity at this
sampling depth; it is not a robust claim of an overall lead. OTFX wins 12/35
individual effects. The geometric OTFX/ASM time ratio is **1.079**, or 7.9%
slower, so large absolute wins in Rings/Binarypath/Laseretch offset many smaller
losses in the arithmetic mean. ASM frame-count differences are retained in
the TSV; these are complete-effect comparisons, not equal-frame comparisons.

This final comparison uses **two samples of at least 0.2 seconds**, otherwise
the same flags/input/affinity described below. The before/after optimization
screens used three 0.3-second samples. Small differences remain provisional,
particularly given the reported activity by another agent. No ASM rebuild or
fetch occurred: the oracle remains the frozen ASM revision
`c2be6411d3e4d5002f160dc0cbd10af7cb3a3889`, SHA256
`ae0cf2e8a62c208b42f78cee60d9d4c948ac9c07145a83a96aef6235934a7171`.

Both Odin binaries use `-o:speed -microarch:native -debug`, assertions enabled,
existing scoped bounds-check exclusions, CPU 2, seed 1, terminal 200x50, dense
input/default canvas 190x46, frame-rate 0, stdout `/dev/null`. Measurements
include the entire CLI initialization, effect build, playback and cleanup.
The native harness runs three samples of at least 0.3 seconds per variant;
CPU and peak RSS come from `wait4`. The log labels `rust` and `odin` mean
**frozen before Odin** and **candidate Odin** in these experiments. No build,
capture or profile ran concurrently with a benchmark in this pass **from this
agent**. The user confirmed another agent was also timing workloads, so machine
contention is possible; small differences remain provisional.

Unstable peak RSS grows from 10504 to 12584 KiB; its shared-duration columns
and temporary build grouping push arena residency higher. Most other RSS
changes are small; every value is retained in the TSV. No allocation-free
unit-test claim is made by this pass.

## Duration-gated effects (separate diagnostics)

Both wrappers add `--virtual-clock` to the same CLI. The native harness uses
`BENCH_MATRIX_RAIN_TIME=1 BENCH_STORM_TIME=1`, three 0.3-second samples, CPU 2.
These are fixed logical one-second weather workloads with initialization and
cleanup; they are **not** one-second real-time playback or part of the 35-effect
aggregate. Native RSS avoids the Python launcher memory floor.

| Effect | Before/after mean wall ms | Before/after CPU ms | Before/after RSS KiB | Frames |
|---|---:|---:|---:|---:|
| Matrix | 59.8 / 62.8 | 59.6 / 62.6 | 10484 / 10432 | 1297 / 1297 |
| Thunderstorm | 9.0 / 4.3 | 8.9 / 4.2 | 11828 / 11904 | 251 / 251 |

**Matrix is a measured exception:** six alternating batches reproduce
60.118 → 63.002 ms (4.8% slower) for the complete before/after binaries.
An isolated control, copying final source and restoring only the old Matrix
procedure, measures 64.340 ms versus 62.982 ms with the sample guard (three
alternating pairs, all favor the guard). Thus removing the guard does not fix
the whole-binary difference in this screen. Retain this simple guard, report
the regression, and defer attributing the remaining difference to code layout
or shared-machine conditions until uncontended timings are available. The
control source and binary are preserved; no production changes were discarded.

`clock.log`, `clock-alternating.log`, `matrix-control.log` and their TSV/JSON
files contain the raw evidence. Python-run RSS is not interpreted as engine RSS.

## Effect audit and preserved contracts

The Python reference phase loops and the frozen Odin implementation were
checked for the changed effects. RNG draws and their order, activation ticks,
completion clocks, sample arithmetic and final publication boundaries stay
unchanged. Exact byte emission can differ when redundant dirty rows disappear;
rendered cells on every frame must still match.

| Effect | Applied pattern, or reason unchanged |
|---|---|
| Beams | Already compacts active groups and appearance lanes; already skips held samples. |
| Binarypath | Separate compact collapse list replaces the all-source collapse scan. Publish the three-tick fade only at boundaries; retain its 21-tick life and final wipe. Removed the now-unused per-source phase tags. |
| Blackhole | Compact consuming/exploding star lists, separate rotating ring, hide non-ring stars once at collapse entry. Skip completed formation/collapse movement and held pulses. Preserve the extra consumption completion tick and the global explosion hold. |
| Bouncyballs | Install flight appearance once, publish landing pose/glyph once, and evaluate six-tick fade boundaries only. Keep the original final hold. |
| Bubbles | Already uses compact active bubbles and shrinking member spans; floating geometry is shared per bubble and colors have sample guards. |
| Burn | Already tracks active smoke and an ordered live ignition window, with next-update ticks. Preserve smoke RNG ordering. |
| Colorshift | Visit the palette lanes only when the global palette sample advances; likewise the final fade. Keep cycle and final-hold clocks. |
| Crumble | Four-tick weakening/flash samples, phase-entry dust appearance, compact reset lanes after their final changing sample. Preserve fall/vacuum RNG and reset completion duration. |
| Decrypt | Already uses batched timeline changes, a typing window and compact slow lanes; held samples and discovered fades are guarded. |
| Errorcorrect | Skip held three-tick flashes/wipes/fades; publish final position and layer reset at the existing arrival boundary. Active lifetime remains unchanged. |
| Expand | `group_values` shares easing for equal durations on its common clock; publish colors only when the eased sample changes. Preserve the forced final pose/color/layer. |
| Fireworks | Previous pass already shares shell motion, compacts active particles and guards phase/held appearance publication. |
| Highlight | Already has active slots and two-tick palette guards. |
| Laseretch | Evaluate source cooling only on three-tick boundaries and spark colors only at their configured boundaries. Preserve source retirement, spark movement and RNG. |
| Matrix | Resolve fade samples only on configured boundaries; the active list still advances and retires on its original clock. Rain randomness is untouched. |
| Middleout | Already shares axis motion and submits only changed integer coordinates; global color boundaries are guarded. |
| Orbittingvolley | Compact launched-particle list replaces scans of all sources; install colors once at launch. Preserve launcher work and the `age == steps` layer reset, including the prior completion predicate. |
| Overflow | Already uses live rows and delay gates. Row advancement and random release ordering remain required. |
| Pour | Skip held gradient calculations and repeated settled coordinates/colors; retain the boundary restoring initial appearance and original life. |
| Print | Sample glyph/color only every three ticks; retain row scrolling, carriage motion and the 18-tick appearance life. |
| Rain | Install drop appearance once, publish landing pose/glyph once, and evaluate three-tick fades only. Preserve random release order and final hold. |
| Randomsequence | Evaluate appearance only at configured gradient boundaries; retain Dynamic nil-color restoration and its longer lifetime. |
| Rings | Rebuild active motion slots at phase transitions, compact completed external/home lanes, and use their count for completion. Preserve external motion across early transitions and waypoint RNG order. Color holds were already guarded. |
| Scattered | Already shares duration samples, compacts active lanes and guards color samples. |
| Slice | `group_values` shares easing for equal durations. One common tick replaces identical per-particle ticks; compact IDs/origins/group slots. Preserve all three directions and fill semantics. |
| Slide | Install Dynamic colors once, sample fades only on changes, stop submitting settled motion. Keep group release order, original lifetime and forced final coordinate/color. |
| Smoke | Already consumes `sample_timeline_changes`; publications are sparse. The contiguous sampler still checks arrivals. Replacing that scan would be a separate scheduling experiment, not a new tool in this pass. |
| Spotlights | Already skips unchanged lighting and visits light bounds plus previously lit particles. |
| Spray | Already compacts active lanes and guards 20-tick color samples; preserve arrival layer reset. |
| Swarm | Already uses active lanes and bounded `sequence_batch` chunks with build-time choreography; no whole-animation cache added. |
| Sweep | Publish five-tick samples only at boundaries; preserve reactivation, second-pass override and terminal sample. |
| Synthgrid | Compact active cells instead of scanning the full canvas, with two-tick generation guards. Preserve build RNG, one block launch per tick and group completion accounting. |
| Thunderstorm | Guard held lightning, spark/text glow, and pre/poststorm fades. Preserve strike retirement, reactivation, RNG and elapsed-time transitions. |
| Unstable | Share explosion/reassembly easing by duration through `group_values`. Skip rumble particle loops when neither offset nor color changed, including the reset to zero offset after jitter. Keep RNG/delay updates and Dynamic restoration at tick 39. |
| VHStape | Skip held two-tick snow samples and repeated final white redraw frames. Scene activation still publishes immediately, even when an interrupted scene resumes on an odd tick. |
| Waves | Skip repeated glyph/shared-appearance publication in the prebuilt wave lane. Final-sample guards and compact active lanes already existed. |
| Wipe | Already has compact active IDs, held-sample guards and explicit re-entry publication. |

## Validation and reproduction

- `odinfmt -w src/effects`, `odin check src`, optimized debug build: pass.
- 222/222 standard captures match every rendered frame, 214 byte-exact.
- 534/534 option/seed/color cases match every rendered frame, 514 byte-exact.
  These cover fast/slow motion, held gradients, three Slide directions plus
  merge/reverse, Slice directions and elastic easing, Synthgrid concurrency,
  early Rings phase transitions, three input-color modes, Unicode, background
  and bold styles, and two RNG seeds.
- Byte differences are confined to Blackhole, Colorshift and Waves; reconstructed
  row canvases, frame counts, output prefix and terminal cleanup agree.
- The parity tool uses the local `third_party/ttfx` binary (checkout `54d21f0`),
  distinct from the frozen ASM timing oracle above. The full diagnostic reports 13 equal frame counts, 24 accepted reference
  frame-count differences and **zero failures**. This checks completion/final
  content, not exact animation equivalence with ASM.
- The full unit-test suite was not rerun, per the user's request. The existing
  Expand arrival test was updated to read the shared-duration slot; only that
  test and the Unstable/Synthgrid boundary tests were selected for a targeted run.
  All three passed. The prior 82/86 result
  and four known allocation failures remain open; this is not an all-tests-pass claim.

Artifacts and exact commands are under `/tmp/otfx-pattern-pass-20260926/`.
`before-source/src` preserves the incoming working tree; `before` is the frozen
Fireworks-holds binary. `first-pass` is the first candidate, `after` is final.
`bench.log` measured the first 19 effects; `bench-final.log` supersedes Binarypath,
Blackhole and Crumble and adds Rings/Waves after the last changes. The final `asm-fresh.log` is the later 35-effect run against ASM requested for
the complete chart, including unchanged effects for a current aggregate.

```sh
odin build src -o:speed -microarch:native -debug -out:/tmp/otfx-pattern-pass-20260926/after
odin build bench -o:speed -out:/tmp/otfx-pattern-pass-20260926/bench \
  -define:REFERENCE_BENCH_BINARY=/tmp/otfx-pattern-pass-20260926/before \
  -define:OTFX_BENCH_BINARY=/tmp/otfx-pattern-pass-20260926/after
BENCH_MIN_SECONDS=0.3 taskset -c 2 /tmp/otfx-pattern-pass-20260926/bench 3 \
  binarypath blackhole bouncyballs colorshift crumble errorcorrect expand laseretch \
  orbittingvolley pour print rain randomsequence slice slide sweep synthgrid unstable vhstape
BENCH_MIN_SECONDS=0.3 taskset -c 2 /tmp/otfx-pattern-pass-20260926/bench 3 \
  binarypath blackhole crumble rings waves
UV_CACHE_DIR=/tmp/uv-cache uv run python /tmp/otfx-pattern-pass-20260926/capture.py
UV_CACHE_DIR=/tmp/uv-cache uv run python /tmp/otfx-pattern-pass-20260926/options.py
odin build tools/parity -o:speed -out:/tmp/otfx-pattern-pass-20260926/parity
TTFX_ASM=force /tmp/otfx-pattern-pass-20260926/parity
```

Binary SHA256:

- Before: `4cfa809086c1e6cd529b6309797af9874152e79256bfd4b033c7f2afc0a2dae5`.
- After: `6db6e5594698c3553299436d94b167aee0a4c0ce0d512904f34fd5e595a9ef84`.

Final comparison command (explicit effect list excludes duration-gated effects):

```sh
odin build bench -o:speed -out:/tmp/otfx-pattern-pass-20260926/bench-asm \
  -define:REFERENCE_BENCH_BINARY=/tmp/ttfx-asm-c2be6411/target/release/ttfx \
  -define:OTFX_BENCH_BINARY=/tmp/otfx-pattern-pass-20260926/after
TTFX_ASM=force BENCH_MIN_SECONDS=0.2 taskset -c 2 /tmp/otfx-pattern-pass-20260926/bench-asm 2 \
  beams binarypath blackhole bouncyballs bubbles burn colorshift crumble decrypt \
  errorcorrect expand fireworks highlight laseretch middleout orbittingvolley \
  overflow pour print rain randomsequence rings scattered slice slide smoke \
  spotlights spray swarm sweep synthgrid unstable vhstape waves wipe
```

Nothing committed; the root `otfx` executable was not replaced.
