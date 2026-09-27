# Prepared RGB increments

2026-09-26, rejected experiment. This follows the active-filter changes.
The paired benchmark finds no material full-effect improvement. Reverted with
user approval; source and tests match the pre-experiment snapshot exactly.
Experimental source and results remain under `/tmp/otfx-prepared-gradient-20260926/`.
No earlier changes were discarded or committed.

## Change

`engine.Color_Gradient` stores the endpoints, step count, and three signed
integer channel increments. `gradient_prepare` calculates the floor divisions;
`gradient_sample_step` multiplies/adds/clamps and returns the exact endpoint on
the final step. Positive and negative directions must be prepared separately.
The value occupies 24 bytes on this machine; it performs no allocation itself.

- `src/engine/color.odin`: common prepared sampling used by gradient palette
  construction and the existing one-shot sampler. Palette construction already
  hoisted its divisions; this consolidates that arithmetic rather than claiming
  a new optimization there.
- `src/engine/batch.odin`: prepare each gradient once per action/batch or timeline,
  rather than calculating increments for each sample.
- `src/effects/beams.odin`: prepare foreground fades in both directions during
  build. Dynamic input color mode additionally prepares background fades.
  Existing nullable foreground/background behavior, holds, and phase order stay.
- `tests/prepared_gradient.odin`: explicit rounding, clamping, reversed direction,
  large-step-count, and final-endpoint checks.

Other effects still calling the one-shot sampler do not automatically retain
prepared increments across frames. There is no global cache or new scheduler.
Beams replaces 6 bytes of endpoint colors per particle with 48 bytes of prepared
foreground gradients; dynamic mode adds another 48 bytes per particle. Thus this
is not a memory reduction even though observed process peak RSS varied downward.

Odin's installed `core:math/ease/flux.odin` already prepares a floating-point
start/difference/rate. Its runtime uses a pointer-keyed map of tweens, delay and
callback handling, and scalar easing on updates; it is not an array-fill API.
Flux was inspected, not substituted or benchmarked.

## Paired full-effect measurements

Frozen before/after binaries, `-o:speed -microarch:native -debug`, CPU 2,
terminal 200x50, input 190x46, seed 1, frame rate 0, stdout `/dev/null`.
Two samples with a minimum 0.5 seconds per sample batch. No concurrent builds,
tests, or profiles during measurements. Harness `rust` means the frozen Odin
before binary. ASM was not rerun.

| Measurement | Before | After |
| --- | ---: | ---: |
| 35-effect mean best wall | 37.826 ms | 37.934 ms |
| 35-effect mean child CPU | 37.809 ms | 37.917 ms |
| Mean peak RSS | 12,841 KiB | 12,802 KiB |
| Beams best wall | 21.9 ms | 21.7 ms |
| Bubbles best wall | 56.7 ms | 56.1 ms |
| Spotlights best wall | 38.6 ms | 38.6 ms |

Geometric speedup: 0.9999x. No effect regressed more than 2% in this screen.
All 35 frame counts match. These results are effectively flat and do not prove
that the extra Beams storage earns its cost. The aggregate is a fresh paired
measurement, not directly interchangeable with earlier runs at different times.
[All per-effect wall/CPU/RSS measurements](prepared-gradient.tsv).

## Validation

- Changed files formatted; `odin check src` and native optimized/debug build pass.
- 80 tests: 76 pass, same four pre-existing allocation tests fail:
  `appearance_packet_survives_placement_changes`,
  `bounded_playback_reuses_build_storage`,
  `frame_composition_character_growth_is_amortized`, and
  `rebuilt_output_storage_does_not_grow`.
- 222 standard plus 354 edge-case captures: **576/576 byte-identical**.
- Smoke: 37/37. Parity: 13 matches, 24 existing diagnostic differences, 0 failures.
- Matrix and Thunderstorm included in capture/smoke/parity validation, excluded
  from finite-effect throughput means.

Artifacts: `/tmp/otfx-prepared-gradient-20260926/` holds frozen binaries, hashes,
source snapshots/diff, scripts, tests, captures, parity/smoke output, `screen.log`
(first three effects), and `bench-rest.log` (remaining 32). Root `./otfx` unchanged.

```sh
BENCH_MIN_SECONDS=0.5 taskset -c 2 /tmp/otfx-prepared-gradient-20260926/bench 2 beams bubbles spotlights
BENCH_MIN_SECONDS=0.5 taskset -c 2 /tmp/otfx-prepared-gradient-20260926/bench 2 binarypath blackhole bouncyballs burn colorshift crumble decrypt errorcorrect expand fireworks highlight laseretch middleout orbittingvolley overflow pour print rain randomsequence rings scattered slice slide smoke spray swarm sweep synthgrid unstable vhstape waves wipe
```
