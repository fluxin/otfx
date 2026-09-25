# Compact cache versus ttfx ASM

Fresh comparison of the working tree after the 24-byte appearance-cache change.
Odin build: `odin build src -o:speed -microarch:native` (compiler
`dev-2026-09-nightly:a2fb372`). ttfx is the exported `origin/asm-zen5` revision
`ac940f2e11c95ef7e6d9e6d0c8b37d389a4e5e75`, release build, forced with
`TTFX_ASM=force`. Its binary SHA256 remains
`a1788a30978f735fd716ed30f5b2279bd07b4b89bb994c47c0b9612e1dab315c`.
Odin binary SHA256 is
`df29112c0eb1df21673475023f8494fa804540349223c87d37d9ffd3eba8dafa`.

The native CLI harness runs identical dense 190x46 input on a 200x50 canvas,
seed 1, frame rate 0, stdout `/dev/null`, three repeats, minimum sample 0.3 s.
This run is not CPU-pinned. Matrix and Thunderstorm are excluded from the
35-effect throughput aggregate. ASM is measured first in each pair.

ASM is **1.33x faster by geometric mean**. It wins 28 effects; Odin wins six;
Highlight rounds to a tie. Errorcorrect is a near tie. Mean best wall is
58.1 / 73.0 ms (ASM / Odin), mean child CPU 58.3 / 73.1 ms, and mean peak RSS
87.8 / 13.5 MiB. Odin uses about 6.5x less resident memory.

Frame counts differ for 21 of 35 effects, so this is complete CLI throughput,
not identical simulation work. Even equal frame counts do not establish equal
per-frame work. `/dev/null` does not measure terminal-emulator cost; ASM emits
cached full rows, whereas Odin emits sparse changes.

| Effect | ASM ms | Odin ms | ASM frames | Odin frames |
| --- | ---: | ---: | ---: | ---: |
| beams | 24.4 | 46.0 | 732 | 890 |
| binarypath | 372.2 | 311.3 | 1891 | 1932 |
| blackhole | 129.0 | 134.2 | 1800 | 1743 |
| bouncyballs | 54.5 | 95.2 | 9093 | 10393 |
| bubbles | 86.6 | 138.6 | 11742 | 11658 |
| burn | 41.0 | 67.4 | 3175 | 3237 |
| colorshift | 21.5 | 35.4 | 528 | 528 |
| crumble | 80.0 | 93.1 | 1835 | 2159 |
| decrypt | 30.8 | 63.3 | 5438 | 5480 |
| errorcorrect | 27.5 | 26.7 | 5237 | 5221 |
| expand | 50.7 | 51.3 | 302 | 302 |
| fireworks | 121.9 | 153.7 | 1553 | 1516 |
| highlight | 7.0 | 7.0 | 129 | 129 |
| laseretch | 85.3 | 118.9 | 14306 | 14307 |
| middleout | 29.2 | 26.7 | 235 | 235 |
| orbittingvolley | 27.6 | 49.0 | 1156 | 1156 |
| overflow | 37.9 | 24.1 | 306 | 164 |
| pour | 32.7 | 49.1 | 7160 | 7160 |
| print | 12.9 | 19.1 | 10057 | 10057 |
| rain | 40.0 | 47.6 | 4737 | 4736 |
| randomsequence | 8.3 | 7.5 | 208 | 208 |
| rings | 142.2 | 194.7 | 1566 | 1566 |
| scattered | 52.2 | 91.1 | 418 | 420 |
| slice | 26.5 | 23.0 | 368 | 368 |
| slide | 28.2 | 37.3 | 375 | 375 |
| smoke | 23.6 | 26.8 | 565 | 630 |
| spotlights | 36.6 | 65.9 | 800 | 780 |
| spray | 41.2 | 77.9 | 661 | 1253 |
| swarm | 210.1 | 244.3 | 5041 | 4312 |
| sweep | 6.9 | 13.6 | 220 | 220 |
| synthgrid | 9.5 | 18.1 | 619 | 617 |
| unstable | 66.5 | 100.5 | 530 | 592 |
| vhstape | 34.6 | 51.0 | 736 | 726 |
| waves | 25.9 | 37.0 | 633 | 633 |
| wipe | 7.9 | 9.0 | 138 | 138 |

## Current hot spots

User-space cycle sampling (`perf record -e cycles:u -F 999`), 30 complete CLI
runs per effect, same input/canvas/seed/frame rate, profiled separately from
the benchmark. Percentages are self samples in optimized symbols; inlined
callees are attributed to the containing symbol, not separately measured.

| Effect | Sampled hot spots |
| --- | --- |
| Colorshift | 73.1% `emit_changed_cell`, 22.1% `next_frame` |
| Decrypt | 40.3% `next_frame`, 24.1% `emit_changed_cell`, 16.3% `run_effect_once`, 3.1% string equality |
| Binarypath | 31.8% `emit_changed_cell`, 30.9% `binarypath_next`, 23.2% `raster_consume_changes`, 5.1% bit-array iteration |

Colorshift emission disassembly shows output-builder descriptor copies around
the append, code-entry lookup, runtime append dispatch, policy checks, and
last-emitted Visual publication. Samples concentrate around descriptor stores;
sampling skid prevents treating those individual instructions as a proven
microarchitectural cause. RGB decimal formatting is not the dominant cost in
this prepared-code workload.

Source-backed next experiments, not implemented performance claims:

1. Keep one output builder across cell emission; reduce per-cell descriptor
   round trips and move fixed color-policy branches out of the inner path.
   Measure the complete renderer and preserve preview/emission semantics.
2. Reduce repeated effect work: Decrypt visits all characters during slow
   playback, including completed characters, and returns the same selection
   each frame. Colorshift visits all characters even on held palette ticks.
   Dense active ranges and scheduled updates are candidates before adding SIMD.
3. Binarypath's active eight-bit motion loop is a candidate for wide arithmetic;
   its raster membership lists involve dependent indexed accesses and are less
   naturally vectorizable. Preserve rounding, random order, and overlapping-cell
   winner rules in any experiment.

ASM source uses u32 visual handles in the cell grid, cached encoded rows,
AVX-512 dirty-byte scans, and an unrolled four-cell loop with AVX2 byte copies.
Its frame loop calls `next_frame`, `render_frame`, then `writev_all` each frame;
there is no batching of multiple animation frames. Odin already retains the
raster, but still compares/publishes logical Visual records and assembles output
per changed cell. These source differences explain plausible work savings;
their individual contributions have not been isolated experimentally.

A separate 20-run Colorshift counter collection, including shell/launch overhead,
measured 15.84B / 6.63B instructions, 3.50B / 1.90B cycles, and 7.45M / 11.45M
cache misses (Odin / ASM). Odin executes about 2.39x the instructions despite
fewer counted cache misses. This does not support cache thrashing as the primary
explanation for that workload; it does not rule out every memory bottleneck.

Raw timings, profiles, annotated emission, counters, harness, and frozen Odin
binary are under `/tmp/otfx-asm-packed/`. The previous 1.44x comparison is under
`/tmp/otfx-asm-current/`. No production code or third-party checkout changed
during this measurement.
