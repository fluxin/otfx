# Shared frame writer

The frame emitter now constructs one `strings.Builder` over its retained output
buffer and passes it through cell emission. Cursor moves, erased cells, prepared
appearances, and dynamic appearances all append through that writer. The output
buffer descriptor is published back once after the frame. No effect API or
effect implementation changes are needed to receive the optimization.

This removes per-cell builder descriptor copies while keeping `write_character`
as the common prepared/dynamic output path and keeping last-emitted-state
publication in the renderer. The shared ownership rules are documented in
[architecture.md](architecture.md).

Validation: 40 tests and 222 exact before/after CLI captures pass, including
input-color policy, preview/emission separation, clipping, overlapping cells,
and fixed-population allocation checks. `odin check src`, formatting, native
build, and `git diff --check` pass.

Both binaries use `-o:speed -microarch:native`. The 35-effect CLI screen uses
200x50 canvas, dense 190x46 input, seed 1, frame rate 0, stdout `/dev/null`,
three repeats, and 0.3-second minimum samples. The baseline is the compact-cache
binary from the fresh ASM comparison. All before/after frame counts match.

| Metric | Before | Shared writer |
| --- | ---: | ---: |
| Mean best wall | 70.8 ms | 69.8 ms |
| Mean child CPU | 70.9 ms | 69.9 ms |
| Mean peak RSS | 13.5 MiB | 13.5 MiB |
| Colorshift best wall | 34.1 ms | 30.3 ms |
| Waves best wall | 35.4 ms | 31.5 ms |
| Binarypath best wall | 305.0 ms | 299.2 ms |
| Wipe best wall | 8.3 ms | 8.7 ms |

The geometric speedup is 1.02x. Wipe's best wall is about 4% worse, although its
mean wall and CPU round equal. A longer five-repeat, one-second-minimum recheck
also has worse Wipe best wall (8.5 / 8.9 ms) but equal mean wall (8.9 / 8.9 ms)
and CPU (8.8 / 8.8 ms). This is not an across-the-board best-time win. The change
is retained for simpler shared ownership and the repeatable gain in dense
prepared-appearance workloads; it adds no retained storage.

This does not implement component-level SoA or vectorized dirty publication.
`Character` is SoA at the outer level, but `Visual` and the render record still
contain interleaved fields. Moving those fields into authoritative columns,
with bulk mutation producing field-specific dirty masks, is a separate layout
experiment. It must preserve scalar setter semantics without introducing a
second mirrored appearance store. Character-indexed masks still need raster
mapping before they can become cell/row-indexed masks.

Frozen binaries are `/tmp/otfx-asm-packed/otfx` and
`/tmp/otfx-asm-packed/shared-writer`. The adapted benchmark, full raw results,
longer recheck, and capture script/log are in `/tmp/otfx-shared-writer/`.
