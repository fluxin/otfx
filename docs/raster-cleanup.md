# Raster cleanup validation

This records the cleanup before the subsequent compact appearance cache.
See [appearance-cache.md](appearance-cache.md) for that change and its results.

This cleanup replaces manual effect dirty calls with setters, uses Odin's
`bit_array.Bit_Array`, and groups membership links and the typed code ID in a
naturally aligned 16-byte record. It removes generation stamps, the character
queue, the separate emitted-code comparison, and the temporary cell writer.
Logical `Visual` remains authoritative; encoded bytes are derived data.

Waves retains one compiled age-to-code timeline rather than repeated symbol,
color, code, and narrowed frame-index arrays. Decrypt releases build-only typing
data and retains full-width user palette indices. Colorshift resolves distinct
symbols with a build-only map. No effect calls `mark_character_dirty` during
playback; the low-level API remains for direct external writers.

## Correctness

- All 39 tests pass, including encoded/raw transitions, input color policy,
  individual appearance setters, a wave timeline above 65,536 frames, and a
  ciphertext palette above 256 colors.
- All 222 CLI captures match the original native baseline exactly: 37 effects,
  seed 42, virtual clock, frame rate 0, plain/no-color/SGR always/SGR dynamic/
  xterm/clipped fixtures. Canvas is 40x12, or 7x3 centered/wrapped for clipping;
  Matrix and Thunderstorm use one logical second.
- The incoming snapshot passed its 35 tests but failed 11 of those captures.
- `odinfmt`, `odin check src`, the native optimized build, and checks of
  accuracy, parity, docs, and common tool packages pass.
- The existing fixed-population playback allocation checks pass.

## Native measurements

Both sides use `-o:speed -microarch:native`. The real CLI benchmark uses dense
200x50 input, seed 1, frame rate 0, stdout `/dev/null`, three repeats, and a
0.3-second minimum sample. These are short screening measurements, not a claim
of a universal speedup. Matrix and Thunderstorm are excluded from throughput.

| Baseline | Mean best wall, before / cleanup | Geometric speedup | Mean peak RSS, before / cleanup |
| --- | --- | --- | --- |
| Earlier validated retained renderer | 73.0 / 77.9 ms | 0.99x | 14.7 / 12.7 MiB |
| Incoming in-flight snapshot | 75.4 / 78.5 ms | 0.97x | 13.1 / 12.7 MiB |

The first row preceded the final selection-bitmap simplification; the second
uses the final implementation. Both cover all 35 finite effects. Per-effect
wall, CPU, RSS, and frame counts are in `raster-cleanup-benchmark.tsv`. The older
`retained-raster-benchmark.tsv` describes the earlier retained renderer, not this
cleanup. The incoming snapshot has correctness failures, so its faster encoded
paths are not equivalent-output wins.

Performance remains mixed. Compared with the earlier validated renderer,
Colorshift improves from 62.7 to 36.8 ms, while Binarypath regresses from 237.1 to
374.4 ms. Compared with the incoming snapshot, the aggregate is about 3% slower
by geometric mean. This is a correctness and ownership cleanup with a documented
performance cost; performance validation is not an across-the-board pass.

`strings.Builder` now writes directly into the destination frame buffer or code
pool. A generic `strings.write_int` experiment was rejected: holding the setter
implementation fixed, the existing small decimal helper reduced Bubbles from
171.8 to 148.8 ms and Laseretch from 142.2 to 123.3 ms. The shared helper remains;
the custom `Code_Buffer`, `code_write`, and duplicate decimal implementation do
not. A native profile also identified formatting and byte append work in the
regressing path. Further formatting/cache work needs its own measured change.

Raw logs, captures, frozen binaries, and the formatter profile are under
`/tmp/otfx-cleanup/`; the reviewed incoming snapshot is under
`/tmp/otfx-review-q5atPj/`. Temporary paths are local evidence, not durable build
dependencies. No comparison checkout under `third_party` was changed.
