# Prepared brightness and squared distance

2026-09-26. Retained two independent Spotlights changes: prepare immutable HSL
colors during build, and compare squared distances before calculating falloff.

## API and scope

`engine.color_to_hsl(Color) -> HSL_Color` uses Odin's native linalg conversion.
`engine.adjust_color_brightness` is a proc group accepting RGB `Color` or
prepared `HSL_Color`. RGB callers use the same conversion and rounding path;
callers that repeatedly vary brightness can keep HSL in their build state.
There is no map, cache, renderer change, or prepared animation.

Spotlights stores one 24-byte HSL foreground per input particle. Its background
HSL column exists only for Dynamic existing-color handling. Original RGB colors
remain available for full brightness without a reverse conversion. Build-time
storage uses the effect's existing lifetime allocator.

`engine.line_length_squared` uses `linalg.length2`, retaining the terminal's
optional doubled row delta. Spotlights selects the nearest light and tests its
radius in squared space. Only candidates in the falloff region need a square
root. Negative falloff-start values (the CLI permits falloff above one) retain
the original behavior. Travel-duration calculations continue using actual
lengths.

The audit covered every effect's `line_length`, `sqrt`, and brightness caller.
Spotlights is the repeated distance-comparison consumer; the others need actual
lengths for travel timing or geometry. Spotlights also varies the brightness
factor continuously. Most other brightness calls are already build-time work.
Beams' Dynamic fade endpoints, Binarypath's collapse endpoints, and
Thunderstorm's bright lightning endpoint are remaining fixed-result hoisting
candidates: they should prepare RGB results, rather than add HSL columns.
Those separate changes were not made in this experiment.

## Preserved behavior

Search advances configured ticks and chooses new targets in the same RNG order;
Converge waits for all paths; Expand restores Dynamic nil foregrounds and grows
the light until the existing limit. Candidate bounds, old-lit clearing, color
rounding, final publication, and cleanup stay unchanged.

## Measurements

Frozen whole-CLI binaries, `-o:speed -microarch:native -debug`, assertions enabled,
existing scoped bounds exclusions, CPU 2, seed 1, terminal 200x50, dense default
canvas 190x46, frame-rate zero, stdout `/dev/null`. Three batched samples of at
least 0.5 seconds for each isolated experiment. CPU/RSS use native `wait4`.
These are complete fixed-duration animations including build and cleanup.

| Experiment | Before best ms | After best ms | Mean CPU before/after ms | Peak RSS before/after KiB |
|---|---:|---:|---:|---:|
| Prepared HSL only | 38.4 | 34.2 | 38.6 / 34.1 | 9692 / 9876 |
| Squared distance only | 37.6 | 34.2 | 38.1 / 34.4 | 9664 / 9680 |
| Both | 37.5 | 32.1 | 37.7 / 32.2 | 9652 / 9872 |

Both together reduce best wall by **14.4%** and mean CPU by **14.6%**. All
variants emit 780 frames. The isolated results are separate runs, not additive
percentage claims.

A fresh targeted ASM comparison measures **OTFX 33.2 ms / ASM 28.4 ms** best
wall, mean wall 34.3 / 28.8 ms, mean CPU 34.1 / 28.7 ms, peak RSS 9868 / 48604
KiB, frames 780 / 800. OTFX remains about 17% slower on best wall for this effect.
The timing oracle is the unchanged frozen ASM `c2be6411d3e4d5002f160dc0cbd10af7cb3a3889`,
forced with `TTFX_ASM=force`; no fetch or rebuild occurred. The absolute timings
shifted during the screen, so use paired comparisons, not cross-run subtraction.

The [35-effect before/after screen](spotlights-prepared-benchmark.tsv), two
samples of at least 0.2 seconds, measures unweighted best-wall mean
**30.614 -> 30.449 ms**. No effect regresses by more than 2%; all frame counts
match. This short screen supports retaining the shared API, not a precise
aggregate speedup claim. The prior complete ASM chart remains in
[the pattern pass](effect-patterns-asm.tsv); only Spotlights was refreshed
against ASM here.

## Validation and artifacts

- `odinfmt` on the three modified source files; `odin check src`; native optimized/debug build.
- 222 standard captures across all 37 effects: every byte matches the frozen before binary.
- 60 Spotlights captures: every byte matches; two seeds, three existing-color modes,
  zero/default/tiny/one/extended falloff, one/eight lights, broad beams, fast motion,
  radial gradients, black/white/saturated endpoints, Unicode and foreground/background SGR.
- Dense benchmark-input capture: before/after byte hash matches.
- Targeted parity tool: reference completion/final-content check, not exact ASM animation parity.
- No full unit-suite rerun. The preceding checkpoint work still has four known
  allocation-test failures (82/86); this change does not claim those are resolved.

Raw logs, frozen binaries, before/HSL-only/distance-only source snapshots, capture
scripts and JSON results are under `/tmp/otfx-spotlights-20260926`.

Binary SHA256:

- Before: `6db6e5594698c3553299436d94b167aee0a4c0ce0d512904f34fd5e595a9ef84`
- HSL only: `0cd4a36bc9f72210e1692f6f08d4cd299d77ef212ac3baa19d4ab77c3affa496`
- Distance only: `0bbe322bd96af34f2e53efd0667d16f9366621afebf607cc1b8c8b19a126c638`
- Both: `80b04054f4ca71f123d874b69c0d7ebe52190fa9ba65f283348e2fef1bfac0a8`

Commands (paths abbreviated with the experiment directory):

```sh
odin build src -o:speed -microarch:native -debug -out:/tmp/otfx-spotlights-20260926/both
odin build bench -o:speed -out:/tmp/otfx-spotlights-20260926/bench-both \
  -define:REFERENCE_BENCH_BINARY=/tmp/otfx-spotlights-20260926/before \
  -define:OTFX_BENCH_BINARY=/tmp/otfx-spotlights-20260926/both
BENCH_MIN_SECONDS=0.5 taskset -c 2 /tmp/otfx-spotlights-20260926/bench-both 3 spotlights
# HSL-only/distance-only screens use the corresponding frozen binary.
# The full screen uses the same bench-both, 2 repeats, min 0.2 seconds,
# and all 35 finite effect names (excludes Matrix and Thunderstorm).
odin build bench -o:speed -out:/tmp/otfx-spotlights-20260926/bench-asm \
  -define:REFERENCE_BENCH_BINARY=/tmp/ttfx-asm-c2be6411/target/release/ttfx \
  -define:OTFX_BENCH_BINARY=/tmp/otfx-spotlights-20260926/both
TTFX_ASM=force BENCH_MIN_SECONDS=0.5 taskset -c 2 /tmp/otfx-spotlights-20260926/bench-asm 3 spotlights
```
