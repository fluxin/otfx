# Appearance cache validation

`prepare_visual` interns reusable appearances during build. The overloaded
`set_visual` accepts either a logical `Visual` or its prepared `Visual_Code_Id`;
both publish the same authoritative logical state. `set_character` accepts
either form too. `write_character` writes into the destination `strings.Builder`
without changing the last-emitted state. Build and playback share one encoder.

Dynamic characters cache only color number fragments: two 11-byte RGB buffers
and a native `bit_field u16` containing two four-bit lengths and a validity bit.
`#assert(size_of(Encoded_Colors) == 24)` guards the layout. The naturally aligned
record needs no `#packed` attribute. The render membership/code record remains
16 bytes. These are individual records, not the total character footprint.
Dirty collections remain `bit_array.Bit_Array`.

Color setters invalidate color fragments and prepared bytes. Symbol and bold
setters release prepared bytes but preserve color fragments. Movement, layer,
and visibility preserve appearance caches. UTF-8 symbols and constant ANSI
syntax are appended directly; there is no 64-byte per-character cache or
overflow allocation. Existing input-color policy remains authoritative.

## Validation

- All 40 tests pass, including prepared/raw transitions, input-color policies,
  cache preservation, preview versus emission, and fixed-population allocation.
- All 222 deterministic CLI captures match the preceding cleanup binary:
  37 effects, six fixtures, seed 42, virtual clock, frame rate 0. Fixtures cover
  plain, no-color, SGR Always, SGR Dynamic, xterm, and clipped centered/wrapped
  output. Canvas is 40x12 or 7x3; timed effects use one logical second.
- Formatting, `odin check src`, native optimized build, and accuracy/parity/docs/
  common tool package checks pass. This is Odin regression validation, not a
  claim of byte parity with Rust.

## Native measurements

Both binaries use `-o:speed -microarch:native`. The full CLI comparison uses
dense 200x50 input, seed 1, frame rate 0, stdout `/dev/null`, three repeats, and
a 0.3-second minimum sample. Matrix and Thunderstorm are excluded from the
35-effect throughput aggregate. All observed frame counts match before/after.

| Metric | Before | After |
| --- | ---: | ---: |
| Mean best wall time | 79.1 ms | 71.9 ms |
| Mean child CPU time | 79.3 ms | 71.9 ms |
| Mean peak RSS | 12.7 MiB | 13.5 MiB |
| Binarypath best wall | 376.8 ms | 310.4 ms |
| Bubbles best wall | 149.3 ms | 134.4 ms |
| Colorshift best wall | 37.5 ms | 35.2 ms |
| Decrypt best wall | 64.9 ms | 61.9 ms |
| Waves best wall | 36.8 ms | 36.1 ms |

Geometric wall speedup is **1.09x**. No effect has a worse best wall time in this
run; near ties remain measurement noise. The additional cache costs about 6%
mean peak RSS. Per-effect wall, CPU, RSS, and frame counts are in
[appearance-cache-benchmark.tsv](appearance-cache-benchmark.tsv). This compares
two Odin implementations; the previous ttfx ASM comparison is not refreshed by
these numbers.

## Wide transfers

Native profiles identified emission as a major cost in Colorshift and
Binarypath. Reading `Visual` through a pointer and using
`mem.copy_non_overlapping` for whole-record publication/emission allows native
256-bit loads/stores, verified in disassembly. A separate five-effect screen
holding the 24-byte cache layout fixed measured 1.08x geometric speedup from
these transfer changes (three repeats, 0.5-second minimum samples). That gain is
already included in the full comparison above, not an additional multiplier.

This widens contiguous record transfers; it does not establish SIMD across
multiple characters' effect arithmetic. Variable-length output and raster
membership traversal remain separate costs. The initial 64-byte complete-byte
cache experiment was discarded in favor of the compact color-fragment record.

Frozen binaries, capture scripts/logs, profiles, and raw harness output are in
`/tmp/otfx-appearance-cache/`. Its adapted harness labels the before/after Odin
binaries `rust`/`odin`; the durable table uses their actual roles. Temporary
files are local evidence, not build dependencies. No third-party checkout was
modified.
