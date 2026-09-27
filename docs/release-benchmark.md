# Release benchmark and refreshed previews

2026-09-27, source commit `643a980a`. Single-core renderer, no background writer.
This report supersedes the assertion-enabled timings in
[the integration report](intrusive-main.md) for the current release comparison.

## Release versus frozen ASM

OTFX uses **`-o:speed -microarch:native -disable-assert`**, without `-debug`.
Across 35 finite effects, arithmetic mean wall is **28.903 versus
30.854 ms (-6.32%)**. Geometric OTFX/ASM time is
**1.0182, or 1.82% slower**. OTFX wins **16/35** effects.
These are distinct aggregations; neither establishes a uniform advantage.

| Metric | OTFX | ttfx ASM |
|---|---:|---:|
| Mean wall per effect | 28.90 ms | 30.85 ms |
| Mean child CPU per effect | 28.76 ms | 30.70 ms |
| Mean per-effect maximum RSS | 11.83 MiB | 50.73 MiB |
| Binary size, as built | 1.27 MiB | 2.74 MiB |
| Binary size, stripped copy | 1.25 MiB | 2.74 MiB |

The [complete raw table](release-asm.tsv) includes best/mean wall, child CPU,
maximum RSS, and frame counts. The chart uses mean wall; negative change means
OTFX is faster. RSS is the maximum child RSS across measured samples for that
effect, not a sum across processes. Frame counts differ for 21/35 effects;
this compares completed animations, not equal-frame throughput.

| Effect | OTFX ms | ASM ms | OTFX time change | OTFX RSS MiB | ASM RSS MiB | Frames OTFX / ASM |
|---|---:|---:|---:|---:|---:|---:|
| beams | 13.5 | 11.7 | +15.4% | 11.53 | 37.33 | 890 / 732 |
| binarypath | 157.8 | 183.7 | -14.1% | 19.40 | 223.64 | 1932 / 1891 |
| blackhole | 50.2 | 55.0 | -8.7% | 9.46 | 61.71 | 1743 / 1800 |
| bouncyballs | 33.0 | 29.6 | +11.5% | 9.59 | 43.04 | 10393 / 9093 |
| bubbles | 47.8 | 46.7 | +2.4% | 10.93 | 58.53 | 11658 / 11742 |
| burn | 21.6 | 25.9 | -16.6% | 13.85 | 47.95 | 3237 / 3175 |
| colorshift | 16.3 | 17.2 | -5.2% | 8.53 | 39.06 | 528 / 528 |
| crumble | 37.6 | 49.5 | -24.0% | 9.50 | 66.63 | 2159 / 1835 |
| decrypt | 23.6 | 16.9 | +39.6% | 17.91 | 39.07 | 5480 / 5438 |
| errorcorrect | 12.3 | 22.5 | -45.3% | 9.03 | 43.53 | 5221 / 5237 |
| expand | 17.9 | 16.6 | +7.8% | 9.65 | 45.05 | 302 / 302 |
| fireworks | 51.8 | 62.7 | -17.4% | 10.41 | 60.97 | 1516 / 1553 |
| highlight | 3.3 | 2.8 | +17.9% | 10.59 | 28.88 | 129 / 129 |
| laseretch | 44.1 | 59.6 | -26.0% | 12.62 | 39.63 | 14307 / 14306 |
| middleout | 7.7 | 8.5 | -9.4% | 9.09 | 47.45 | 235 / 235 |
| orbittingvolley | 18.4 | 17.5 | +5.1% | 12.09 | 35.38 | 1156 / 1156 |
| overflow | 10.8 | 12.3 | -12.2% | 17.07 | 18.05 | 164 / 306 |
| pour | 16.7 | 16.8 | -0.6% | 9.46 | 43.09 | 7160 / 7160 |
| print | 6.8 | 6.7 | +1.5% | 12.09 | 38.89 | 10057 / 10057 |
| rain | 16.4 | 19.2 | -14.6% | 9.27 | 47.63 | 4736 / 4737 |
| randomsequence | 3.8 | 3.7 | +2.7% | 9.65 | 28.73 | 208 / 208 |
| rings | 75.0 | 104.4 | -28.2% | 10.38 | 64.94 | 1566 / 1566 |
| scattered | 30.0 | 24.9 | +20.5% | 9.28 | 44.94 | 420 / 418 |
| slice | 5.3 | 6.6 | -19.7% | 9.81 | 31.28 | 368 / 368 |
| slide | 18.1 | 12.7 | +42.5% | 9.65 | 43.17 | 375 / 375 |
| smoke | 13.7 | 9.6 | +42.7% | 11.66 | 67.12 | 630 / 565 |
| spotlights | 31.1 | 26.7 | +16.5% | 9.28 | 48.53 | 780 / 800 |
| spray | 24.1 | 27.1 | -11.1% | 9.08 | 49.88 | 1253 / 661 |
| swarm | 103.3 | 95.4 | +8.3% | 21.57 | 90.03 | 4312 / 5041 |
| sweep | 4.8 | 4.2 | +14.3% | 16.15 | 30.81 | 220 / 220 |
| synthgrid | 8.3 | 5.1 | +62.7% | 13.39 | 33.23 | 617 / 619 |
| unstable | 33.7 | 35.2 | -4.3% | 9.46 | 43.71 | 592 / 530 |
| vhstape | 27.0 | 24.3 | +11.1% | 17.79 | 59.74 | 726 / 736 |
| waves | 21.2 | 15.8 | +34.2% | 9.65 | 45.21 | 633 / 633 |
| wipe | 4.6 | 2.8 | +64.3% | 15.29 | 28.78 | 138 / 138 |

## Assertion-only control

Both control binaries retain `-debug` and identical optimized/native flags;
the only changed flag is `-disable-assert`. Mean wall is
**28.609 → 28.686 ms**
(+0.27%),
with geometric time +0.37%.
There is **no measured aggregate speedup from disabling assertions**. Individual
results are mixed: Wipe is 4.2→4.6 ms in this sweep. All native frame counts match.
See [all 35 assertion-control results](release-assert.tsv); this is not an
argument that assertion overhead is universally zero.

`-debug` emits debugging information and sets `ODIN_DEBUG`; it does not disable
assertions. `-disable-assert` suppresses built-in runtime assertions. No global
`-no-bounds-check` or `-no-type-assert` flag was added. Existing scoped bounds
exclusions remain. The final release/ASM sweep removes `-debug` as requested.
The earlier assertion-enabled release-comparison sample was slightly faster;
these new flags must not be described as a demonstrated performance improvement.

## Binary size

`stat` file sizes, before and after `strip --strip-all -o COPY ORIGINAL`.
Only disposable copies were stripped. Timed binaries and the ASM oracle remain
unchanged. MiB in the README means 1,048,576 bytes. Binary size is separate from
RSS, which includes runtime allocations.

| Build | File bytes | Stripped bytes |
|---|---:|---:|
| assert-debug | 6,131,584 | 1,347,832 |
| noassert-debug | 5,892,456 | 1,310,968 |
| release | 1,327,552 | 1,306,872 |
| asm | 2,872,192 | 2,872,184 |

`assert-debug` is the integrated assertion-enabled binary; `noassert-debug`
is the assertion-only control. `release` has no debug information or runtime
assertions. The ASM binary is already effectively stripped. Debug information
explains most of the original Odin file-size difference; the release file is
1,327,552 bytes and its stripped copy is 1,306,872 bytes.

## Timing-gated diagnostics

Matrix and Thunderstorm are excluded from the 35-effect aggregate. These are
**unpaced wall-clock diagnostics**, with `--rain-time 1` / `--storm-time 1`,
three samples, and the same canvas/seed/output sink as above. Their elapsed
limits dominate wall time and their logical work/frame counts differ. No
throughput ratio is inferred. Unpaced CPU duty is about 99.75% for both.

| Effect | OTFX wall ms | ASM wall ms | OTFX CPU ms | ASM CPU ms | OTFX RSS MiB | ASM RSS MiB | Frames OTFX / ASM |
|---|---:|---:|---:|---:|---:|---:|---:|
| matrix | 1054.4 | 1017.8 | 1051.7 | 1015.3 | 9.55 | 27.50 | 5484 / 14072 |
| thunderstorm | 1003.9 | 1012.9 | 1001.4 | 1010.4 | 11.52 | 52.51 | 5174 / 8076 |

[Exact diagnostic values](release-weather.tsv). Finite-effect performance must
not be combined with these duration-gated runs.

## Validation and previews

The assertion-enabled source passed **87/87 tests**, `odin check`, parity
(13 frame matches, 24 diagnostic differences, zero failures), and all 37 smoke
cases. The release executable additionally passes **756/756 byte-identical
captures** against that assertion-enabled binary: 222 standard cases and 534
option/seed/color cases, including virtual-clock weather. Tests that deliberately
expect assertions continue to run with assertions enabled.

All **37 GIF previews were regenerated** from this source using the native
`tools/docs` pipeline; **1 files differ** from the preceding gallery.
The original gallery is backed up in the artifact directory. All 37 regenerated
GIFs decode successfully at 588×169 pixels, with multiple frames; midpoint and
final-frame contact sheets were generated for visual inspection. Previews use
the existing seed 3, 84×13 canvas, Omarchy input, pinned font chain, and virtual
60 fps clock. Sampling and GIF delays remain tied to logical frame time.

## Reproduce and artifacts

Ryzen 9 9900X3D, CPU 2 only. Seed 1, terminal 200×50, dense input/default canvas
190×46, `--frame-rate 0`, stdout `/dev/null`. Each binary/effect has three batched
samples targeting at least 0.3 seconds. The reference runs first. Whole CLI
construction/build/playback/teardown are included; CPU and maximum RSS use
`wait4`. Own compilation, captures, and GIF generation ran outside timed sweeps.
Terminal-emulator work is excluded. Small differences are not formal
significance claims.

```sh
odin build src -o:speed -microarch:native -disable-assert -out:/tmp/otfx-release
odin build bench -o:speed -define:OTFX_BENCH_BINARY=/tmp/otfx-release -define:REFERENCE_BENCH_BINARY=/tmp/ttfx-asm-c2be6411/target/release/ttfx -out:/tmp/otfx-release-bench
TTFX_ASM=force BENCH_MIN_SECONDS=0.3 taskset -c 2 /tmp/otfx-release-bench 3
odin build tools/docs -o:speed -microarch:native -out:/tmp/otfx-previews
/tmp/otfx-previews
```

The default harness invocation also reports weather separately; the published
finite sweep explicitly selected the 35 finite effects. Exact invocations,
frozen binaries, hashes, size metadata, all timing/capture/preview logs, and
contact sheets are in `/tmp/otfx-release-20260927/`. ASM was not fetched or
rebuilt: revision `c2be6411d3e4d5002f160dc0cbd10af7cb3a3889`, selected with
`TTFX_ASM=force`.

```text
release 059bb801980d714cfe56035c92f6487b640b4c80c8c048a75b5e1afabcf635bf
ASM     ae0cf2e8a62c208b42f78cee60d9d4c948ac9c07145a83a96aef6235934a7171
```
