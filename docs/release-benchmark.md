# Release benchmark and refreshed previews

2026-10-05, working copy on top of `4f9f064`: one `tween` group and
`Appearance_Ramp` for fades and lighting (Spotlights now selects shared IDs
instead of converting HSL per cell), on top of the previous release's run
emission, engine RNG, immutable shared appearances and per-frame
`#no_bounds_check`. The reference is ttfx `921bd551` (v0.5.0 plus two
merges), run single-threaded (`TTFX_THREADS=1`); OTFX is single-threaded.

## Summary

OTFX uses **`-o:speed -microarch:native -disable-assert`**, without `-debug`.

| Metric | OTFX | ttfx v0.5.0 |
|---|---:|---:|
| Mean wall per effect, /dev/null | 30.65 ms | 26.61 ms |
| Mean wall per effect, pipe | 32.99 ms | 60.40 ms |
| Mean wall per effect, pty | 44.67 ms | 301.39 ms |
| Bytes written, 35 effects | 584 MB | 9,602 MB |
| Mean per-effect maximum RSS | 11.93 MiB | 22.86 MiB |
| Startup (slide) | 0.3 ms | 0.6 ms |
| Binary size, as built | 1.18 MiB | 3.02 MiB |
| Binary size, stripped copy | 1.16 MiB | 3.02 MiB |

## Throughput by sink

`bench/bench.odin` takes `BENCH_SINK=null|pipe|pty`. With a pipe or a raw
200x50 pseudo-terminal the harness drains every byte itself, 64 KiB per read,
and wall time runs until the last byte arrives; a terminal emulator's parsing
is excluded. The pipe and pty sweeps give the harness a second core
(`taskset -c 1,2`) so the reader does not share the writer's core. Both
programs see the same sink, input, seed and canvas. ttfx publishes its own
speeds into `/dev/null`.

| Sink | OTFX mean wall | ttfx mean wall | Geometric OTFX speedup | OTFX mean CPU | ttfx mean CPU | OTFX faster |
|---|---:|---:|---:|---:|---:|---:|
| `/dev/null` | 30.65 ms | 26.61 ms | 0.86x | 30.47 ms | 26.46 ms | 9/35 |
| pipe | 32.99 ms | 60.40 ms | 1.79x | 32.39 ms | 48.81 ms | 32/35 |
| pty | 44.67 ms | 301.39 ms | 5.11x | 36.64 ms | 101.21 ms | 35/35 |

Into `/dev/null` OTFX wins crumble, errorcorrect, fireworks, middleout, overflow, rings, slice, spotlights and unstable. Through a pipe ttfx keeps
binarypath, scattered and slide. On a pty OTFX finishes first on every effect.
[Raw data for all three sinks](release-fx-sinks.tsv).

| Effect | /dev/null OTFX / ttfx | pipe OTFX / ttfx | pty OTFX / ttfx |
|---|---:|---:|---:|
| beams | 15.1 / 10.3 | 16.1 / 24.1 | 23.0 / 112.8 |
| binarypath | 167.0 / 95.7 | 177.0 / 132.1 | 275.5 / 319.6 |
| blackhole | 54.5 / 53.9 | 57.6 / 76.0 | 70.6 / 207.7 |
| bouncyballs | 37.5 / 26.3 | 40.5 / 116.5 | 45.6 / 860.3 |
| bubbles | 53.8 / 41.1 | 57.6 / 147.1 | 67.1 / 1092.2 |
| burn | 23.3 / 18.3 | 25.7 / 79.7 | 27.6 / 562.3 |
| colorshift | 19.1 / 16.5 | 24.7 / 29.1 | 69.2 / 105.8 |
| crumble | 43.7 / 50.0 | 45.2 / 63.2 | 55.4 / 135.5 |
| decrypt | 19.7 / 15.4 | 22.7 / 71.0 | 43.2 / 517.8 |
| errorcorrect | 13.2 / 17.6 | 14.4 / 114.4 | 18.0 / 900.6 |
| expand | 18.7 / 16.5 | 19.8 / 23.0 | 22.3 / 48.8 |
| fireworks | 53.8 / 54.6 | 59.5 / 91.2 | 61.5 / 190.4 |
| highlight | 4.0 / 2.6 | 5.3 / 6.8 | 5.4 / 23.5 |
| laseretch | 46.9 / 45.4 | 51.2 / 197.7 | 56.6 / 1291.2 |
| middleout | 7.7 / 7.9 | 8.1 / 9.4 | 9.5 / 17.5 |
| orbittingvolley | 21.1 / 15.7 | 22.4 / 31.3 | 24.3 / 120.6 |
| overflow | 12.9 / 13.4 | 15.0 / 19.3 | 29.3 / 62.0 |
| pour | 17.9 / 15.9 | 19.9 / 92.7 | 23.5 / 652.2 |
| print | 7.8 / 7.0 | 9.8 / 134.8 | 17.8 / 1103.7 |
| rain | 19.1 / 17.2 | 20.1 / 68.9 | 23.2 / 434.5 |
| randomsequence | 4.6 / 3.5 | 4.9 / 6.2 | 5.8 / 27.1 |
| rings | 85.6 / 95.7 | 88.9 / 108.8 | 112.1 / 194.9 |
| scattered | 31.0 / 23.8 | 33.4 / 32.5 | 47.4 / 84.2 |
| slice | 5.3 / 6.0 | 5.9 / 11.5 | 8.3 / 46.4 |
| slide | 17.9 / 12.2 | 19.3 / 16.9 | 30.3 / 46.4 |
| smoke | 9.9 / 7.6 | 11.0 / 23.9 | 16.5 / 122.8 |
| spotlights | 22.4 / 28.4 | 23.7 / 46.2 | 29.4 / 150.4 |
| spray | 28.1 / 26.2 | 29.9 / 38.3 | 35.1 / 102.7 |
| swarm | 107.1 / 99.9 | 108.3 / 161.1 | 113.5 / 536.7 |
| sweep | 4.3 / 3.4 | 4.8 / 8.3 | 6.2 / 37.6 |
| synthgrid | 7.3 / 4.7 | 8.2 / 13.6 | 11.4 / 72.2 |
| unstable | 37.5 / 39.2 | 39.8 / 44.3 | 60.4 / 93.8 |
| vhstape | 29.4 / 20.5 | 32.7 / 39.8 | 52.1 / 141.8 |
| waves | 22.4 / 16.1 | 28.0 / 29.7 | 61.0 / 116.1 |
| wipe | 3.0 / 2.7 | 3.3 / 4.7 | 5.4 / 16.7 |

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
| beams | 15.1 | 10.3 | +46.6% | 11.91 | 16.63 | 10.8 | 97.7 | 878 / 732 |
| binarypath | 167.0 | 95.7 | +74.5% | 19.93 | 39.40 | 103.0 | 215.8 | 1909 / 1891 |
| blackhole | 54.5 | 53.9 | +1.1% | 10.23 | 35.38 | 15.4 | 149.0 | 1793 / 1800 |
| bouncyballs | 37.5 | 26.3 | +42.6% | 10.23 | 18.62 | 15.5 | 826.4 | 10378 / 9093 |
| bubbles | 53.8 | 41.1 | +30.9% | 11.48 | 27.51 | 26.5 | 1056.0 | 12184 / 11742 |
| burn | 23.3 | 18.3 | +27.3% | 14.45 | 19.59 | 14.8 | 536.9 | 3218 / 3175 |
| colorshift | 19.1 | 16.5 | +15.8% | 8.91 | 28.24 | 47.1 | 85.3 | 528 / 528 |
| crumble | 43.7 | 50.0 | -12.6% | 10.01 | 33.49 | 19.7 | 94.4 | 2200 / 1835 |
| decrypt | 19.7 | 15.4 | +27.9% | 12.18 | 25.61 | 20.1 | 493.1 | 5442 / 5438 |
| errorcorrect | 13.2 | 17.6 | -25.0% | 9.75 | 18.05 | 8.1 | 862.1 | 5259 / 5237 |
| expand | 18.7 | 16.5 | +13.3% | 10.20 | 18.78 | 3.9 | 32.4 | 302 / 302 |
| fireworks | 53.8 | 54.6 | -1.5% | 10.87 | 29.63 | 10.7 | 136.7 | 1367 / 1553 |
| highlight | 4.0 | 2.6 | +53.8% | 11.16 | 15.04 | 1.3 | 21.5 | 129 / 129 |
| laseretch | 46.9 | 45.4 | +3.3% | 13.38 | 21.76 | 22.9 | 1270.0 | 14307 / 14306 |
| middleout | 7.7 | 7.9 | -2.5% | 9.48 | 18.80 | 1.6 | 9.6 | 235 / 235 |
| orbittingvolley | 21.1 | 15.7 | +34.4% | 11.51 | 16.68 | 10.3 | 109.3 | 1156 / 1156 |
| overflow | 12.9 | 13.4 | -3.7% | 17.63 | 21.32 | 16.2 | 48.4 | 231 / 306 |
| pour | 17.9 | 15.9 | +12.6% | 9.91 | 17.24 | 8.3 | 623.6 | 7160 / 7160 |
| print | 7.8 | 7.0 | +11.4% | 11.44 | 15.79 | 6.4 | 1084.5 | 10057 / 10057 |
| rain | 19.1 | 17.2 | +11.0% | 9.91 | 20.46 | 7.8 | 424.5 | 4760 / 4737 |
| randomsequence | 4.6 | 3.5 | +31.4% | 12.09 | 14.32 | 1.7 | 22.5 | 208 / 208 |
| rings | 85.6 | 95.7 | -10.6% | 11.06 | 36.27 | 27.9 | 94.9 | 1563 / 1566 |
| scattered | 31.0 | 23.8 | +30.3% | 9.91 | 19.64 | 14.9 | 58.4 | 418 / 418 |
| slice | 5.3 | 6.0 | -11.7% | 12.06 | 14.17 | 3.3 | 40.8 | 368 / 368 |
| slide | 17.9 | 12.2 | +46.7% | 12.03 | 15.98 | 12.4 | 33.3 | 375 / 375 |
| smoke | 9.9 | 7.6 | +30.3% | 12.25 | 18.23 | 8.1 | 117.0 | 549 / 565 |
| spotlights | 22.4 | 28.4 | -21.1% | 12.01 | 34.46 | 9.1 | 122.1 | 779 / 800 |
| spray | 28.1 | 26.2 | +7.3% | 9.75 | 20.70 | 13.1 | 76.6 | 1275 / 661 |
| swarm | 107.1 | 99.9 | +7.2% | 22.30 | 50.66 | 28.6 | 461.6 | 4051 / 5041 |
| sweep | 4.3 | 3.4 | +26.5% | 11.26 | 16.01 | 2.5 | 35.6 | 220 / 220 |
| synthgrid | 7.3 | 4.7 | +55.3% | 13.89 | 19.22 | 5.0 | 67.8 | 617 / 619 |
| unstable | 37.5 | 39.2 | -4.3% | 11.88 | 22.45 | 20.3 | 57.4 | 594 / 530 |
| vhstape | 29.4 | 20.5 | +43.4% | 12.07 | 30.26 | 23.9 | 123.0 | 748 / 736 |
| waves | 22.4 | 16.1 | +39.1% | 10.32 | 16.00 | 39.6 | 98.6 | 633 / 633 |
| wipe | 3.0 | 2.7 | +11.1% | 10.04 | 13.86 | 2.4 | 14.8 | 138 / 138 |

## Timing-gated comparison

Matrix (`--rain-time 5`) and Thunderstorm (`--storm-time 1`) run for their
configured time and are excluded above. The harness counts their frames on a
separate run whose output goes through a pipe, so the counts reflect how much
each frame costs to deliver as well as to build: OTFX observed 431,212 and
112,071 frames against ttfx's 80,857 and 10,041. Wall and CPU are bounded by
the duration gates. [Diagnostic values](release-fx-weather.tsv).

## Validation and previews

- 88/88 tests pass; `odin check` passes for `src` (with and without frame
  stats), `tools/docs`, `tools/accuracy`, `tools/parity`, `bench` and
  `bench/phases`.
- All 37 effects run to completion at 200x50 with assertions enabled.
- The release executable matches the assertion-enabled executable byte for byte
  on **740/740 captures**: the 222 cases of `bench/capture.py` and 518
  option, seed and color cases (14 cases across 37 effects, including
  virtual-clock weather, xterm, no-color, all three existing-color modes,
  Unicode and tab input, clipping, anchors, wrapping and reused canvases).
- The tween and ramp refactor is byte-identical to the previous build for all
  37 effects across seeds 1, 2 and 7 in default, no-color, xterm and the
  existing-color modes. Spotlights' light levels differ from per-cell HSL
  conversion by at most 3/255 per channel.
- Parity: 13 frame matches, 24 diagnostic differences, 0 failures.
- All 37 GIF previews were regenerated; only Spotlights changed.

## Reproduce

Ryzen 9 9900X3D. Seed 1, terminal 200x50, dense input/default canvas 190x46,
`--frame-rate 0`. Three batched samples of at least 0.3 seconds per binary and
effect; the reference runs first. CPU and maximum RSS use `wait4`. An unrelated
process used about 1.8 cores on the other CCD (CPUs 6-11 and 18-23) throughout;
small differences are not significance claims.

```sh
odin build src -o:speed -microarch:native -disable-assert -out:/tmp/otfx-release
# ttfx v0.5.0+: git archive 921bd551 from the ttfx checkout, then cargo build --release
odin build bench -o:speed -define:OTFX_BENCH_BINARY=/tmp/otfx-release -define:REFERENCE_BENCH_BINARY=/path/to/ttfx-921bd551/target/release/ttfx -out:/tmp/otfx-release-bench
TTFX_THREADS=1 BENCH_MIN_SECONDS=0.3 taskset -c 2 /tmp/otfx-release-bench 3
TTFX_THREADS=1 BENCH_MIN_SECONDS=0.3 BENCH_SINK=pipe taskset -c 1,2 /tmp/otfx-release-bench 3
TTFX_THREADS=1 BENCH_MIN_SECONDS=0.3 BENCH_SINK=pty taskset -c 1,2 /tmp/otfx-release-bench 3
odin build tools/docs -o:speed -microarch:native -out:/tmp/otfx-previews
/tmp/otfx-previews
```

```text
otfx release 022a5ec41d7a26ef2ff3c044414770b31d5e6de4c8bc30651d1d1e691c3cac20
```
