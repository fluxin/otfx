# Program-wide bounds-check experiment

2026-09-26. Current radix-grouping source, identical frozen source and build
flags except `-no-bounds-check`. No production source or build defaults changed;
nothing committed. Compiler: `dev-2026-09-nightly:a2fb372`.

```sh
odin build /tmp/otfx-no-bounds-20260926/source/src -o:speed -microarch:native -debug -out:/tmp/otfx-no-bounds-20260926/before
odin build /tmp/otfx-no-bounds-20260926/source/src -o:speed -microarch:native -debug -no-bounds-check -out:/tmp/otfx-no-bounds-20260926/after
odin build bench -o:speed -out:/tmp/otfx-no-bounds-20260926/bench -define:OTFX_BENCH_BINARY=/tmp/otfx-no-bounds-20260926/after -define:REFERENCE_BENCH_BINARY=/tmp/otfx-no-bounds-20260926/before
```

## Paired result

35 finite effects, complete build and playback, seed 1, terminal 200x50,
input 190x46, frame rate 0, stdout `/dev/null`, pinned to CPU 2. Two samples;
each sample batches children for at least 0.5 seconds. Compilation, tests,
captures, and parity finished before benchmarking. Harness `rust` is the
checked Odin baseline; ASM was not measured in this experiment.

| Metric | Checked | Unchecked | Reduction |
| --- | ---: | ---: | ---: |
| Mean best wall | 36.829 ms | 34.171 ms | 7.21% |
| Mean child CPU | 36.929 ms | 34.074 ms | 7.73% |
| Mean peak RSS | 13,180 KiB | 12,999 KiB | 1.37% |

Geometric wall speedup: **1.0835x**. All 35 frame counts match. No effect
regressed more than 2% in this screen. Per-effect differences and sample means
are retained in the [full table](no-bounds-check.tsv). In particular, Beams'
checked mean wall was 19.7 ms versus its best 16.1 ms; the headline uses the
same best-wall aggregation as prior comparisons, not this slower sample.

| Effect | Checked best wall | Unchecked best wall |
| --- | ---: | ---: |
| Beams | 16.1 ms | 15.0 ms |
| Bubbles | 55.3 ms | 49.2 ms |
| Spotlights | 39.0 ms | 36.8 ms |
| Binarypath | 183.1 ms | 170.6 ms |
| Fireworks | 75.5 ms | 68.9 ms |
| Colorshift | 27.5 ms | 22.1 ms |
| Middleout | 26.6 ms | 26.3 ms |

## Validation and scope

- Unchecked optimized/debug tests: 80 total, 76 pass, same four existing
  allocation-test failures (`appearance_packet_survives_placement_changes`,
  `bounded_playback_reuses_build_storage`,
  `frame_composition_character_growth_is_amortized`,
  `rebuilt_output_storage_does_not_grow`).
- 222 standard plus 354 edge captures: **576/576 byte-identical** between builds.
- Smoke 37/37; unchecked parity 13 matches, 24 existing diagnostic differences,
  zero failures. Matrix/Thunderstorm remain validation cases, excluded from the
  finite-effect timing mean.
- The flag disables bounds checking program-wide. Covered inputs behaved
  identically; these checks do not establish that every possible input is safe
  without runtime bounds checks. The production defaults remain checked.

Artifacts: `/tmp/otfx-no-bounds-20260926/` contains source/test snapshots,
`before` and `after` binaries, hashes, validation logs, capture scripts/results,
`bench.log`, `summary.json`, and `bench.sh` with the exact 35-effect command.
The root `./otfx` executable was not replaced.
