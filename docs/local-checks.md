# Scoped bounds checks and assertions

2026-09-26. Experiments against the current radix-grouping source. The scoped
version (two fixed-size bit-array writes plus scoped annotations) was accepted
and integrated into `src/engine/{render,group,codes}.odin`. Build defaults and
the root executable remain unchanged; nothing committed. All variants are
preserved in `/tmp/otfx-local-checks-20260926/`.

`#no_bounds_check` can apply to a procedure, loop, or block. It removes bounds
checks within that scope, without disabling runtime assertions. The separate
compiler flag `-disable-assert` disables built-in runtime assertions throughout
the build. `-o:speed` does not imply either flag; compile-time `#assert` remains.
Verified against installed Odin `dev-2026-09-nightly:a2fb372` help and runtime.

## Paired measurements

35 finite effects, complete CLI build and playback, seed 1, terminal 200x50,
input 190x46, frame rate zero, stdout `/dev/null`, CPU 2. Each variant used a
frozen checked baseline, two samples, and at least 0.5 seconds of child runs per
sample. Flags: `-o:speed -microarch:native -debug`. No compilation, tests, or
profiling overlapped timings. Each row below is a separate paired run; baseline
variation means the differences between rows are not an isolated control.

| Variant | Before wall | After wall | Reduction | CPU before/after | RSS before/after |
| --- | ---: | ---: | ---: | ---: | ---: |
| Two fixed-size bit-array writes | 36.846 ms | 34.851 ms | 5.41% | 36.760 / 34.737 ms | 13,181 / 13,240 KiB |
| Those writes plus scoped tags | 36.914 ms | 34.497 ms | 6.55% | 36.871 / 34.491 ms | 13,156 / 13,119 KiB |
| Assertions disabled only | 37.034 ms | 37.060 ms | -0.07% | 37.063 / 37.060 ms | 13,234 / 13,103 KiB |

Wall is the unweighted mean of each effect's best sample; CPU and peak RSS are
unweighted per-effect means. All frame counts match. Neither bounds-related
variant had an effect more than 2% slower in this screen. Assertions-off raw
regressions over 2% were Blackhole, Pour, Smoke, and Wipe; these were not
rechecked because the aggregate gave no reason to adopt the flag.
Full per-effect data: [local-checks.tsv](local-checks.tsv).

A separate six-effect comparison of bit-array-only versus bit-array plus tags
measured 51.5 versus 50.5 ms mean best wall, geometric speedup 1.02x. The extra
tags helped Colorshift (22.8 to 21.9 ms) and Waves (24.8 to 24.0 ms), while
Middleout stayed at 26.2 ms. This is not a full-suite attribution measurement.

## Candidates and index guarantees

The simplest candidate is replacing two `bit_array.set` calls in `render.odin`
with Odin's `bit_array.unsafe_set`: `mark_cell_dirty` and the dirty-row write in
`frame_build`. The arrays are allocated at their final size with zero bias.
Cell indices are clipped or retained from published membership; the row is the
valid cell index divided by positive width. Clear and row-buffer swapping keep
the allocation and logical length intact. Generic `set` additionally handles
growth, length updates, and bias. `unsafe_set` already has a scoped
`#no_bounds_check` inside the standard library.

The additional scoped-tag experiment covers:

- `group.odin`: radix scatter loop, where histogram prefix sums partition the
  destination and bucket counters advance exactly the counted number of times.
- `render.odin`: cell insert/remove and queued composition, where checked queue
  insertion validates particle IDs and clipping establishes cell indices;
  dirty-cell indexing uses the same fixed-size bit-array invariant.
- `codes.odin`: packet writes after one checked slice establishes a 4- or
  51-byte slot. Rune encoding is at most four bytes. Padding remains checked.

Public setter checks and runtime assertions remain enabled in both candidates.
The accepted version includes both native bit-array writes and the additional
scopes. Disabling all assertions gave no measured aggregate benefit and was
not adopted. Production source was compared byte-for-byte with the validated,
benchmarked scoped variant after integration; no benchmark rerun was needed.

The scoped result of 34.497 ms is 12.14% more time than the earlier recorded
ASM `c2be6411` mean of 30.763 ms. Matching it would require another 3.734 ms,
or 10.82% reduction. This is historical context, not a fresh paired ASM run.

## Validation

Each candidate: 576 exact captures (222 standard plus 354 edge), smoke 37/37,
parity 13 matches and 24 existing diagnostic differences, zero parity failures.
Each bounds-related candidate has 81 tests with 77 passing and the same four
existing allocation-test failures. The bit-array test covers widths 1, 64, and
65, final-cell writes, clipped departure, clearing, and retained logical lengths.
The scoped packet test checks glyph widths, styles, padding, and guard bytes.
After integration, `odin check src` and the optimized native/debug build pass.
Both new tests are retained: 82 tests, 78 pass, the same four allocation failures.

Assertions-off has 80 tests with 75 passing: the same four allocation failures
plus `particle_constructor_rejects_unrepresentable_id`. That test deliberately
expects an assertion; with it disabled, invalid construction reaches a bounds
trap instead. Valid-input captures still match. The four existing failures are
`appearance_packet_survives_placement_changes`,
`bounded_playback_reuses_build_storage`,
`frame_composition_character_growth_is_amortized`, and
`rebuilt_output_storage_does_not_grow`.

Artifact subdirectories `bits`, `local`, and `asserts` retain frozen sources,
binaries, validation logs, `bench.sh`, `bench.log`, and per-effect results.
ASM was not rebuilt or benchmarked in this experiment.
