# Release benchmark and refreshed previews

2026-10-05, working copy on top of `4f9c140` (jj change `nzrkrxtm`): one engine
RNG, changed-cell run emission, lane-only SGR prefixes, immutable shared
appearances with prepared gradient fades, per-frame `#no_bounds_check`, and
storage fixes in Wipe, Sweep, Binarypath, Decrypt, Vhstape, Smoke, Overflow,
Print and Orbittingvolley. The reference is ttfx `921bd551` (v0.5.0 plus two
merges), whose fx engine replaced the ASM engine of the previous report. It runs
single-threaded (`TTFX_THREADS=1`); OTFX is single-threaded.

## Summary

OTFX uses **`-o:speed -microarch:native -disable-assert`**, without `-debug`.

| Metric | OTFX | ttfx v0.5.0 |
|---|---:|---:|
| Mean wall per effect, /dev/null | 29.54 ms | 25.29 ms |
| Mean wall per effect, pipe | 31.95 ms | 59.07 ms |
| Mean wall per effect, pty | 41.81 ms | 287.55 ms |
| Bytes written, 35 effects | 584 MB | 9,602 MB |
| Mean per-effect maximum RSS | 11.90 MiB | 23.07 MiB |
| Startup (slide) | 0.3 ms | 0.6 ms |
| Binary size, as built | 1.20 MiB | 3.02 MiB |
| Binary size, stripped copy | 1.18 MiB | 3.02 MiB |

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
| `/dev/null` | 29.54 ms | 25.29 ms | 0.86x | 29.40 ms | 25.13 ms | 8/35 |
| pipe | 31.95 ms | 59.07 ms | 1.79x | 31.35 ms | 48.39 ms | 32/35 |
| pty | 41.81 ms | 287.55 ms | 5.17x | 34.47 ms | 96.62 ms | 35/35 |

Into `/dev/null` OTFX wins crumble, errorcorrect, fireworks, middleout,
overflow, rings, slice and spray. Through a pipe ttfx keeps binarypath,
scattered and slide. On a pty OTFX finishes first on every effect.
[Raw data for all three sinks](release-fx-sinks.tsv).

| Effect | /dev/null OTFX / ttfx | pipe OTFX / ttfx | pty OTFX / ttfx |
|---|---:|---:|---:|
| beams | 14.6 / 10.1 | 15.8 / 21.2 | 19.8 / 102.6 |
| binarypath | 156.1 / 90.8 | 167.4 / 128.5 | 251.6 / 296.7 |
| blackhole | 52.6 / 51.1 | 54.3 / 70.6 | 64.3 / 185.3 |
| bouncyballs | 36.4 / 26.0 | 39.4 / 117.6 | 43.0 / 816.3 |
| bubbles | 52.2 / 39.6 | 55.8 / 167.1 | 62.1 / 1043.8 |
| burn | 22.3 / 17.5 | 24.8 / 78.9 | 26.1 / 531.5 |
| colorshift | 18.3 / 15.8 | 23.5 / 26.8 | 62.8 / 95.0 |
| crumble | 41.0 / 44.2 | 43.0 / 57.1 | 50.3 / 129.7 |
| decrypt | 19.2 / 14.6 | 22.6 / 74.1 | 37.6 / 488.5 |
| errorcorrect | 12.9 / 17.2 | 13.8 / 121.1 | 16.4 / 853.1 |
| expand | 18.3 / 16.3 | 18.4 / 20.0 | 20.9 / 49.8 |
| fireworks | 53.4 / 53.5 | 54.3 / 70.5 | 56.5 / 175.2 |
| highlight | 3.5 / 2.6 | 3.7 / 5.1 | 4.5 / 21.7 |
| laseretch | 45.9 / 44.5 | 48.8 / 193.7 | 56.4 / 1239.6 |
| middleout | 7.7 / 7.8 | 7.8 / 9.1 | 9.8 / 15.8 |
| orbittingvolley | 20.9 / 15.8 | 22.0 / 29.5 | 23.9 / 127.0 |
| overflow | 12.4 / 12.9 | 14.6 / 19.4 | 27.8 / 55.8 |
| pour | 18.3 / 15.9 | 19.3 / 87.6 | 21.7 / 628.2 |
| print | 7.2 / 6.5 | 9.3 / 132.4 | 19.1 / 1089.0 |
| rain | 18.5 / 17.0 | 19.7 / 66.6 | 21.8 / 422.0 |
| randomsequence | 4.1 / 3.4 | 4.5 / 7.2 | 4.7 / 23.6 |
| rings | 82.4 / 92.1 | 88.7 / 109.4 | 105.2 / 178.6 |
| scattered | 30.0 / 23.2 | 32.4 / 31.3 | 45.1 / 79.5 |
| slice | 5.2 / 5.8 | 5.7 / 11.2 | 7.4 / 45.3 |
| slide | 17.1 / 11.8 | 19.1 / 16.9 | 28.2 / 41.7 |
| smoke | 9.5 / 7.3 | 10.6 / 23.7 | 15.0 / 123.2 |
| spotlights | 30.2 / 25.7 | 32.7 / 45.4 | 37.3 / 144.8 |
| spray | 25.8 / 26.1 | 28.6 / 35.2 | 32.3 / 103.1 |
| swarm | 98.5 / 89.9 | 103.0 / 148.7 | 106.6 / 490.5 |
| sweep | 4.2 / 3.3 | 4.6 / 7.8 | 5.8 / 35.9 |
| synthgrid | 7.0 / 4.6 | 8.0 / 13.1 | 10.9 / 67.9 |
| unstable | 35.9 / 34.0 | 39.2 / 44.3 | 55.8 / 90.6 |
| vhstape | 28.5 / 20.1 | 32.1 / 39.2 | 49.2 / 137.8 |
| waves | 20.8 / 15.4 | 27.4 / 32.3 | 58.5 / 118.9 |
| wipe | 2.9 / 2.6 | 3.2 / 4.7 | 5.1 / 16.1 |

## Complete finite-effect comparison

Mean wall into `/dev/null`; negative change means OTFX is faster. RSS is the
maximum child RSS across measured samples. Bytes are one complete run's output.
Frame counts differ for 21/35 effects, so these are complete-animation costs
rather than equal-frame throughput. [Raw CPU, wall, RSS and frame data](release-fx.tsv).

| Effect | OTFX ms | ttfx ms | OTFX time change | OTFX RSS MiB | ttfx RSS MiB | OTFX MB written | ttfx MB written | Frames OTFX / ttfx |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| beams | 14.6 | 10.1 | +44.6% | 11.90 | 16.54 | 10.8 | 97.7 | 878 / 732 |
| binarypath | 156.1 | 90.8 | +71.9% | 19.89 | 39.69 | 103.0 | 215.8 | 1909 / 1891 |
| blackhole | 52.6 | 51.1 | +2.9% | 10.20 | 35.55 | 15.4 | 149.0 | 1793 / 1800 |
| bouncyballs | 36.4 | 26.0 | +40.0% | 10.20 | 18.70 | 15.5 | 826.4 | 10378 / 9093 |
| bubbles | 52.2 | 39.6 | +31.8% | 11.42 | 27.44 | 26.5 | 1056.0 | 12184 / 11742 |
| burn | 22.3 | 17.5 | +27.4% | 14.59 | 19.63 | 14.8 | 536.9 | 3218 / 3175 |
| colorshift | 18.3 | 15.8 | +15.8% | 9.02 | 28.02 | 47.1 | 85.3 | 528 / 528 |
| crumble | 41.0 | 44.2 | -7.2% | 10.02 | 33.39 | 19.7 | 94.4 | 2200 / 1835 |
| decrypt | 19.2 | 14.6 | +31.5% | 12.20 | 25.82 | 20.1 | 493.1 | 5442 / 5438 |
| errorcorrect | 12.9 | 17.2 | -25.0% | 9.77 | 18.20 | 8.1 | 862.1 | 5259 / 5237 |
| expand | 18.3 | 16.3 | +12.3% | 10.30 | 18.84 | 3.9 | 32.4 | 302 / 302 |
| fireworks | 53.4 | 53.5 | -0.2% | 10.88 | 29.54 | 10.7 | 136.7 | 1367 / 1553 |
| highlight | 3.5 | 2.6 | +34.6% | 11.27 | 15.02 | 1.3 | 21.5 | 129 / 129 |
| laseretch | 45.9 | 44.5 | +3.1% | 15.26 | 21.66 | 22.9 | 1270.0 | 14307 / 14306 |
| middleout | 7.7 | 7.8 | -1.3% | 9.58 | 18.84 | 1.6 | 9.6 | 235 / 235 |
| orbittingvolley | 20.9 | 15.8 | +32.3% | 11.64 | 16.82 | 10.3 | 109.3 | 1156 / 1156 |
| overflow | 12.4 | 12.9 | -3.9% | 17.66 | 21.12 | 16.2 | 48.4 | 231 / 306 |
| pour | 18.3 | 15.9 | +15.1% | 9.96 | 17.21 | 8.3 | 623.6 | 7160 / 7160 |
| print | 7.2 | 6.5 | +10.8% | 11.46 | 15.81 | 6.4 | 1084.5 | 10057 / 10057 |
| rain | 18.5 | 17.0 | +8.8% | 9.93 | 20.55 | 7.8 | 424.5 | 4760 / 4737 |
| randomsequence | 4.1 | 3.4 | +20.6% | 12.14 | 14.29 | 1.7 | 22.5 | 208 / 208 |
| rings | 82.4 | 92.1 | -10.5% | 11.04 | 36.70 | 27.9 | 94.9 | 1563 / 1566 |
| scattered | 30.0 | 23.2 | +29.3% | 9.95 | 19.68 | 14.9 | 58.4 | 418 / 418 |
| slice | 5.2 | 5.8 | -10.3% | 12.12 | 14.05 | 3.3 | 40.8 | 368 / 368 |
| slide | 17.1 | 11.8 | +44.9% | 10.33 | 16.01 | 12.4 | 33.3 | 375 / 375 |
| smoke | 9.5 | 7.3 | +30.1% | 12.36 | 18.34 | 8.1 | 117.0 | 549 / 565 |
| spotlights | 30.2 | 25.7 | +17.5% | 9.94 | 35.98 | 9.6 | 122.1 | 779 / 800 |
| spray | 25.8 | 26.1 | -1.1% | 9.69 | 20.48 | 13.1 | 76.6 | 1275 / 661 |
| swarm | 98.5 | 89.9 | +9.6% | 22.18 | 55.96 | 28.6 | 461.6 | 4051 / 5041 |
| sweep | 4.2 | 3.3 | +27.3% | 11.27 | 16.04 | 2.5 | 35.6 | 220 / 220 |
| synthgrid | 7.0 | 4.6 | +52.2% | 13.89 | 19.20 | 5.0 | 67.8 | 617 / 619 |
| unstable | 35.9 | 34.0 | +5.6% | 11.88 | 22.35 | 20.3 | 57.4 | 594 / 530 |
| vhstape | 28.5 | 20.1 | +41.8% | 12.21 | 30.25 | 23.9 | 123.0 | 748 / 736 |
| waves | 20.8 | 15.4 | +35.1% | 10.32 | 15.93 | 39.6 | 98.6 | 633 / 633 |
| wipe | 2.9 | 2.6 | +11.5% | 9.88 | 13.93 | 2.4 | 14.8 | 138 / 138 |

## Timing-gated comparison

Matrix (`--rain-time 5`) and Thunderstorm (`--storm-time 1`) run for their
configured time and are excluded above. The harness counts their frames on a
separate run whose output goes through a pipe, so the counts reflect how much
each frame costs to deliver as well as to build: OTFX observed 425,816 and
114,318 frames against ttfx's 80,122 and 10,093. Wall and CPU are bounded by the
duration gates. [Diagnostic values](release-fx-weather.tsv).

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
- Run emission was checked by replaying both terminal streams into a screen
  model: every frame of all 37 effects shows the same glyph, bold and colors in
  every cell, in default, no-color, xterm and all existing-color modes. The
  later effect changes are byte-identical for seeds 1, 2 and 7.
- Parity: 13 frame matches, 24 diagnostic differences, 0 failures.
- All **37 GIF previews were regenerated**; 27 changed with the new random
  stream, exactly the effects that draw random numbers. All decode at 588x169
  with multiple frames.

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
otfx release 52c93af00bed1663fceced3694a954f17b7a4459d589e9a136e6c8ab98deefb9
```
