# Release benchmark and refreshed previews

2026-11-12: index-linked 12-byte `Render_Node` and 16-byte `Render_Cell` grid,
separable O(1) xterm cube lookup and 3-digit SGR decimal LUT, suite-wide shared
`Appearance_Id` / `Appearance_Ramp` palettes across all 37 effects, cached
single-column glyph widths, and consolidated `@(rodata) Effect_Catalog`. The
reference is **ttfx `14ed2742` (`v0.5.1`)**, which includes `DifferentialOutput`
for TTYs, run single-threaded (`TTFX_THREADS=1`); OTFX is single-threaded.

## Summary

OTFX uses **`-o:speed -microarch:native -disable-assert`**, without `-debug`.

| Metric | OTFX | ttfx v0.5.1 |
|---|---:|---:|
| Mean wall per effect, /dev/null | 27.53 ms | 28.31 ms |
| Mean wall per effect, pipe | 29.90 ms | 65.21 ms |
| Mean wall per effect, pty | 41.79 ms | 115.99 ms |
| Bytes written (pipe), 35 effects | 587 MB | 9,602 MB |
| Mean per-effect maximum RSS | 12.09 MiB | 22.02 MiB |
| Startup (slide) | 0.4 ms | 0.7 ms |
| Binary size, as built | 1.27 MiB | 3.02 MiB |
| Binary size, stripped copy | 1.25 MiB | 3.02 MiB |

## Throughput by sink

`bench/bench.odin` takes `BENCH_SINK=null|pipe|pty`. With a pipe or a raw
200x50 pseudo-terminal the harness drains every byte itself, 64 KiB per read,
and wall time runs until the last byte arrives; a terminal emulator's parsing
is excluded. Both programs see the same sink, input, seed and canvas. ttfx
v0.5.1 activates its `DifferentialOutput` filter on TTY/PTY sinks while writing
full frames to pipes and `/dev/null`.

| Sink | OTFX mean wall | ttfx mean wall | Geometric OTFX speedup | OTFX mean CPU | ttfx mean CPU | OTFX faster |
|---|---:|---:|---:|---:|---:|---:|
| `/dev/null` | 27.53 ms | 28.31 ms | 1.05x | 27.20 ms | 27.97 ms | 20/35 |
| pipe | 29.90 ms | 65.21 ms | 2.16x | 29.13 ms | 53.65 ms | 33/35 |
| pty | 41.79 ms | 115.99 ms | 2.74x | 33.31 ms | 107.65 ms | 34/35 |

Into `/dev/null` OTFX now leads overall (`1.05x` geometric mean, `27.53 ms` vs
`28.31 ms`) and wins 20/35 effects: beams, blackhole, burn, crumble,
errorcorrect, expand, fireworks, highlight, laseretch, middleout, overflow,
pour, rain, randomsequence, rings, slice, smoke, spotlights, spray and unstable
(plus a tie on sweep). Through a pipe OTFX wins 33/35 (`2.16x` geometric). On a
pty OTFX wins 34/35 (`2.74x` geometric) while using `0.31x` the CPU of ttfx
v0.5.1's `DifferentialOutput`.
[Raw data for all three sinks](release-fx-sinks.tsv).

| Effect | /dev/null OTFX / ttfx | pipe OTFX / ttfx | pty OTFX / ttfx |
|---|---:|---:|---:|
| beams | 11.3 / 12.0 | 12.3 / 25.9 | 18.3 / 56.4 |
| binarypath | 151.0 / 112.5 | 147.9 / 133.5 | 249.5 / 456.0 |
| blackhole | 44.6 / 64.6 | 45.9 / 72.8 | 58.1 / 143.0 |
| bouncyballs | 37.1 / 29.0 | 38.5 / 128.7 | 42.6 / 200.1 |
| bubbles | 49.3 / 43.5 | 52.7 / 173.8 | 61.1 / 290.1 |
| burn | 18.3 / 19.4 | 21.0 / 87.3 | 25.3 / 105.1 |
| colorshift | 20.3 / 17.7 | 25.8 / 31.8 | 73.1 / 149.6 |
| crumble | 37.5 / 48.9 | 39.8 / 62.5 | 51.4 / 141.1 |
| decrypt | 19.6 / 17.2 | 22.2 / 83.7 | 40.4 / 160.1 |
| errorcorrect | 11.9 / 19.3 | 13.1 / 125.3 | 16.5 / 119.7 |
| expand | 16.8 / 19.1 | 16.2 / 22.8 | 20.5 / 32.6 |
| fireworks | 46.4 / 59.9 | 47.7 / 76.0 | 57.5 / 151.6 |
| highlight | 2.5 / 3.5 | 2.7 / 6.7 | 3.9 / 8.4 |
| laseretch | 40.6 / 47.0 | 44.1 / 203.3 | 52.5 / 310.9 |
| middleout | 7.4 / 9.7 | 8.4 / 10.2 | 9.1 / 15.8 |
| orbittingvolley | 19.9 / 17.6 | 21.4 / 31.3 | 23.5 / 62.3 |
| overflow | 11.3 / 13.0 | 14.1 / 23.8 | 29.0 / 23.9 |
| pour | 16.2 / 17.4 | 18.4 / 108.2 | 21.3 / 146.5 |
| print | 7.2 / 7.1 | 10.5 / 145.0 | 18.9 / 152.7 |
| rain | 18.1 / 19.1 | 21.4 / 78.9 | 21.5 / 116.5 |
| randomsequence | 3.5 / 4.0 | 4.7 / 7.0 | 4.3 / 12.5 |
| rings | 77.2 / 97.2 | 82.7 / 110.6 | 102.3 / 211.3 |
| scattered | 29.4 / 25.9 | 32.9 / 37.0 | 46.2 / 84.4 |
| slice | 5.1 / 6.9 | 6.3 / 13.3 | 7.8 / 17.6 |
| slide | 16.9 / 12.9 | 19.5 / 19.8 | 30.2 / 51.2 |
| smoke | 7.9 / 8.0 | 9.0 / 27.3 | 14.4 / 42.8 |
| spotlights | 18.2 / 29.3 | 20.1 / 62.1 | 25.4 / 74.8 |
| spray | 26.6 / 27.3 | 30.2 / 45.8 | 33.1 / 78.9 |
| swarm | 98.5 / 96.0 | 106.8 / 172.7 | 114.0 / 272.1 |
| sweep | 3.8 / 3.8 | 4.0 / 11.5 | 5.8 / 14.5 |
| synthgrid | 7.6 / 5.1 | 8.6 / 18.5 | 12.2 / 30.6 |
| unstable | 31.1 / 35.2 | 34.3 / 49.3 | 54.9 / 104.7 |
| vhstape | 24.7 / 23.4 | 29.9 / 42.6 | 50.0 / 71.9 |
| waves | 22.8 / 15.4 | 30.1 / 27.9 | 62.3 / 137.6 |
| wipe | 3.0 / 2.9 | 3.3 / 5.5 | 5.7 / 12.3 |

## Hardware counters

User-space `perf stat` counters for one complete run of each finite effect into
`/dev/null` on CPU 2, the median of three. L2 misses and fill sources use Zen's
per-core `l2_cache_req_stat` and `ls_any_fills_from_sys` events, so they count
only the measured process. Kernel work and the terminal side are excluded.

| Counter, 35 effects | OTFX | ttfx v0.5.0 |
|---|---:|---:|
| Instructions | 14.05 G | 11.95 G |
| Cycles | 5.10 G | 4.45 G |
| Instructions per cycle | 2.76 | 2.69 |
| Instructions per frame | 146 k | 127 k |
| L1 data loads | 6.91 G | 6.78 G |
| L1 data miss rate | 5.73% | 7.48% |
| L2 misses | 54.1 M | 61.7 M |
| L1 fills served by L3 | 58.8 M | 64.0 M |
| L1 fills served by DRAM | 53 k | 73 k |
| Branch miss rate | 2.46% | 2.31% |
| Data-TLB misses | 410 k | 64 k |

OTFX retires instructions at a similar rate and misses its caches less: its
per-effect L2 misses are a geometric 0.43x of ttfx's. The `/dev/null` gap is
instruction count, about 1.21x per effect, concentrated in Randomsequence, Beams, Highlight, Binarypath and Smoke.
[Per-effect counters](release-fx-counters.tsv).

## Complete finite-effect comparison

Mean wall into `/dev/null`; negative change means OTFX is faster. RSS is the
maximum child RSS across measured samples. Bytes are one complete run's output.
Frame counts differ for 21/35 effects, so these are complete-animation costs
rather than equal-frame throughput. [Raw CPU, wall, RSS and frame data](release-fx.tsv).

| Effect | OTFX ms | ttfx ms | OTFX time change | OTFX RSS MiB | ttfx RSS MiB | OTFX MB written | ttfx MB written | Frames OTFX / ttfx |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| beams | 11.3 | 12.0 | -5.8% | 10.96 | 13.59 | 11.0 | 97.7 | 878 / 732 |
| binarypath | 151.0 | 112.5 | +34.2% | 18.42 | 35.89 | 103.0 | 215.8 | 1909 / 1891 |
| blackhole | 44.6 | 64.6 | -31.0% | 10.21 | 29.35 | 15.6 | 149.0 | 1793 / 1800 |
| bouncyballs | 37.1 | 29.0 | +27.9% | 11.47 | 18.38 | 15.5 | 826.4 | 10364 / 9093 |
| bubbles | 49.3 | 43.5 | +13.3% | 11.49 | 27.02 | 26.5 | 1056.0 | 12184 / 11742 |
| burn | 18.3 | 19.4 | -5.7% | 13.04 | 19.61 | 14.8 | 536.9 | 3218 / 3175 |
| colorshift | 20.3 | 17.7 | +14.7% | 17.01 | 28.25 | 47.3 | 85.3 | 528 / 528 |
| crumble | 37.5 | 48.9 | -23.3% | 12.50 | 33.37 | 19.9 | 94.4 | 2200 / 1835 |
| decrypt | 19.6 | 17.2 | +14.0% | 10.20 | 25.47 | 20.1 | 493.1 | 5442 / 5438 |
| errorcorrect | 11.9 | 19.3 | -38.3% | 9.27 | 18.11 | 8.1 | 862.1 | 5259 / 5237 |
| expand | 16.8 | 19.1 | -12.0% | 9.27 | 15.61 | 3.9 | 32.4 | 302 / 302 |
| fireworks | 46.4 | 59.9 | -22.5% | 10.02 | 23.99 | 10.7 | 136.7 | 1367 / 1553 |
| highlight | 2.5 | 3.5 | -28.6% | 11.11 | 12.23 | 1.3 | 21.5 | 129 / 129 |
| laseretch | 40.6 | 47.0 | -13.6% | 14.00 | 21.35 | 23.0 | 1270.0 | 14307 / 14306 |
| middleout | 7.4 | 9.7 | -23.7% | 11.12 | 18.35 | 1.6 | 9.6 | 235 / 235 |
| orbittingvolley | 19.9 | 17.6 | +13.1% | 10.39 | 13.65 | 10.3 | 109.3 | 1157 / 1156 |
| overflow | 11.3 | 13.0 | -13.1% | 15.43 | 21.09 | 16.2 | 48.4 | 231 / 306 |
| pour | 16.2 | 17.4 | -6.9% | 9.45 | 16.09 | 8.3 | 623.6 | 7160 / 7160 |
| print | 7.2 | 7.1 | +1.4% | 11.16 | 15.68 | 6.4 | 1084.5 | 10057 / 10057 |
| rain | 18.1 | 19.1 | -5.2% | 11.70 | 19.86 | 7.8 | 424.5 | 4760 / 4737 |
| randomsequence | 3.5 | 4.0 | -12.5% | 11.00 | 14.26 | 1.7 | 22.5 | 208 / 208 |
| rings | 77.2 | 97.2 | -20.6% | 12.67 | 36.66 | 28.1 | 94.9 | 1563 / 1566 |
| scattered | 29.4 | 25.9 | +13.5% | 8.70 | 19.09 | 14.9 | 58.4 | 418 / 418 |
| slice | 5.1 | 6.9 | -26.1% | 11.02 | 11.06 | 3.3 | 40.8 | 368 / 368 |
| slide | 16.9 | 12.9 | +31.0% | 11.03 | 15.88 | 12.4 | 33.3 | 375 / 375 |
| smoke | 7.9 | 8.0 | -1.2% | 11.14 | 18.27 | 8.6 | 117.0 | 549 / 565 |
| spotlights | 18.2 | 29.3 | -37.9% | 10.92 | 35.85 | 9.2 | 122.1 | 779 / 800 |
| spray | 26.6 | 27.3 | -2.6% | 12.48 | 20.05 | 13.1 | 76.6 | 1275 / 661 |
| swarm | 98.5 | 96.0 | +2.6% | 20.04 | 55.19 | 28.8 | 461.6 | 4051 / 5041 |
| sweep | 3.8 | 3.8 | +0.0% | 11.64 | 16.02 | 2.5 | 35.6 | 220 / 220 |
| synthgrid | 7.6 | 5.1 | +49.0% | 18.45 | 19.14 | 5.0 | 67.8 | 617 / 619 |
| unstable | 31.1 | 35.2 | -11.6% | 10.95 | 22.40 | 20.3 | 57.4 | 594 / 530 |
| vhstape | 24.7 | 23.4 | +5.6% | 13.39 | 30.17 | 26.2 | 123.0 | 748 / 736 |
| waves | 22.8 | 15.4 | +48.1% | 10.95 | 15.71 | 39.6 | 98.6 | 633 / 633 |
| wipe | 3.0 | 2.9 | +3.4% | 10.71 | 14.02 | 2.4 | 14.8 | 138 / 138 |

## Timing-gated comparison

Matrix (`--rain-time 1`) and Thunderstorm (`--storm-time 1`) run for their
configured time and are excluded above. The harness counts their frames on a
separate run whose output goes through a pipe, so the counts reflect how much
each frame costs to deliver as well as to build: OTFX observed 123,170 and
197,332 frames against ttfx's 23,890 and 14,198 (with Peak RSS 10.22 MiB vs
12.75 MiB on Matrix and 15.82 MiB vs 69.33 MiB on Thunderstorm). Wall and CPU
are bounded by the duration gates. [Diagnostic values](release-fx-weather.tsv).

## Validation and previews

- **92/92 tests pass** in `odin test tests` with memory-leak tracking enabled;
  clean `-o:speed -microarch:native -disable-assert` builds succeed for `src`,
  `bench`, `bench/phases`, `tools/docs`, `tools/accuracy` and `tools/parity`.
- All 37 effects run to completion across `odin test tests` and `./tools/parity/parity`,
  with full final-glyph and non-input blankness verification.
- Parity: **13 frame matches, 24 diagnostic differences, 0 failures**.
- All 37 GIF previews in `docs/images/` were regenerated; **33/37 are byte-for-byte
  identical**, and only `beams`, `bouncyballs`, `fireworks` and `orbittingvolley`
  changed due to their intentional Phase 1/3 fixes.

## Reproduce

Seed 1, terminal 200x50, dense input/default canvas 190x46, `--frame-rate 0`.
Batched samples of at least 0.25 seconds per binary and effect; the reference
runs first. CPU and maximum RSS use `wait4`.

```sh
tools/setup/download_ttfx.sh
third_party/ttfx/bin/build
odin build src -o:speed -microarch:native -disable-assert -out:otfx
odin build bench -o:speed -microarch:native -disable-assert -out:bench/bench
TTFX_THREADS=1 BENCH_MATRIX_RAIN_TIME=1 BENCH_MIN_SECONDS=0.25 ./bench/bench 2
TTFX_THREADS=1 BENCH_MATRIX_RAIN_TIME=1 BENCH_MIN_SECONDS=0.25 BENCH_SINK=pipe ./bench/bench 2
TTFX_THREADS=1 BENCH_MATRIX_RAIN_TIME=1 BENCH_MIN_SECONDS=0.25 BENCH_SINK=pty ./bench/bench 2
```

```text
otfx release 742ccb88578f024ed02d97ba77200f317a6300feece294600f60fea84006bdec
```
