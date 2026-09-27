# Single-pass composition experiment

2026-09-26, uncommitted. The experiment remains in the working tree for review;
it is not an unqualified replacement recommendation. The prior source and
binary are preserved in `/tmp/otfx-single-pass-20260926/`.

## Change and correctness

`compose_frame` processes each deduplicated update once: compute its final
cell, remove the old membership when cell/layer changes, insert the final
membership, and mark visible content changes. Packed stack keys retain the
published layer independently of the particle's requested layer, so pending
changes do not invalidate stack ordering. Cell bytes are still patched after
the queue drains. Ordered removal and insertion are retained.

This removes one queue traversal and one destination calculation per placement
update, with no added production state. `render.odin` is eight lines shorter.
The new regression test covers pending layer changes, interior departure,
hide, and a cell swap with arrivals preceding departures.

## Full-binary results

Native `-o:speed -microarch:native -debug` binaries, CPU 2, terminal 200x50,
input 190x46, seed 1, frame rate zero, stdout `/dev/null`. Two samples per
effect, minimum 0.5 seconds per sample batch. Both sides are Odin; the harness's
`rust` label means the frozen two-pass baseline. ASM was not rerun.

All 35 finite effects were measured. Unweighted mean best wall time changed
from **40.383 to 39.603 ms (-1.93%)**, mean child CPU from **40.349 to 39.540 ms
(-2.00%)**. Geometric wall speedup is **1.008x**. Mean per-effect peak RSS is
12,817 to 12,853 KiB (+0.28%). Every finite-effect frame count matches.

| Effect | Two passes ms | One pass ms | Change |
| --- | ---: | ---: | ---: |
| Binarypath | 204.6 | 185.8 | -9.2% |
| Swarm | 120.9 | 116.8 | -3.4% |
| Middleout | 22.5 | 26.7 | +18.7% |
| Unstable | 46.2 | 49.4 | +6.9% |
| Blackhole | 65.9 | 68.5 | +3.9% |
| Spotlights | 43.3 | 44.7 | +3.2% |

All effects, CPU, RSS and frames are in [the full table](single-pass-composition.tsv).
Only regressions above 2% were repeated: Middleout 23.5 to 28.1 ms (+19.6%),
Unstable 46.1 to 49.0 (+6.3%), Blackhole 69.6 to 72.2 (+3.7%), Spotlights 44.8
to 45.1 (+0.7%). The first three repeated; Spotlights did not retain the initial
size of regression. Absolute timings drifted between screens, so compare
paired results rather than mixing samples from different screens.

Fewer queue passes do not imply fewer stack operations. Interleaving arrivals
with departures can increase the occupied stack that an interior operation
must shift. Removing all departures first can make subsequent insertions
cheaper. The remaining regressions prevent treating this as a general win.

## Measured stack work

Temporary source copies add counters before `ordered_remove` and `inject_at`.
They count the keys shifted and interior operations; none of these counters
were added to production source. Two diagnostic samples produced identical
operation counts. These runs include timer/counter overhead and are not the
full-binary wall measurements above.

| Effect | Compose ms, two/one pass | Insertion keys shifted, two/one pass | Interior insertions, two/one pass |
| --- | ---: | ---: | ---: |
| Middleout | 18.25 / 22.49 | 18,382,651 / 41,712,740 | 311,055 / 332,993 |
| Blackhole | 18.11 / 21.09 | 12,546,131 / 13,723,179 | 102,866 / 270,383 |
| Binarypath | 96.14 / 76.58 | 596,827 / 977,244 | 426,685 / 705,262 |
| Swarm | 34.95 / 30.63 | 529,545 / 873,315 | 290,890 / 416,306 |
| Unstable | 16.16 / 17.95 | 136,837 / 470,331 | 67,714 / 317,460 |

Middleout's removal shifts remain exactly 65,767,747; its increased copying is
on insertion. Unstable's removal shifts also stay unchanged. Binarypath visits
5,815,909 queued updates over the effect: its traversal/destination savings
outweigh the extra stack work. That causal interpretation fits both the phase
split and operation counts; no individual instruction cost was isolated.

Frame counts, queued-update counts, patched cells, dirty rows and emitted byte
counts remain identical in all five diagnostics. The work difference is stack
maintenance, not less visible output. Raw data are `phases-before.tsv` and
`phases-after.tsv` in the artifact directory; `prepare-diagnostics.py` records
the instrumentation.

## Validation and artifacts

- Formatting, `odin check src`, optimized/debug build pass.
- 79 tests: 75 pass, the same four pre-existing allocation tests fail.
- 222/222 deterministic byte-exact captures across 37 effects and six fixtures.
- 37/37 smoke checks; parity 13 match, 24 existing diagnostic differences,
  zero failures.
- No commits; the root executable was not replaced. No prior experiment was
  discarded.

Saved source snapshots, binaries/hashes, diffs, scripts and logs are in
`/tmp/otfx-single-pass-20260926/`. `bench.log` covers the first 14 finite effects;
an invalid fractional Matrix duration stopped that invocation, so
`bench-rest.log` resumes the remaining 21 without repeating completed effects.
Matrix/Thunderstorm are covered by virtual-clock captures, smoke and parity;
they are excluded from finite-effect throughput numbers.

Benchmark commands:

```sh
BENCH_MIN_SECONDS=0.5 BENCH_MATRIX_RAIN_TIME=0.1 BENCH_STORM_TIME=0.1 taskset -c 2 /tmp/otfx-single-pass-20260926/bench 2
BENCH_MIN_SECONDS=0.5 taskset -c 2 /tmp/otfx-single-pass-20260926/bench 2 middleout orbittingvolley overflow pour print rain randomsequence rings scattered slice slide smoke spotlights spray swarm sweep synthgrid unstable vhstape waves wipe
BENCH_MIN_SECONDS=0.5 taskset -c 2 /tmp/otfx-single-pass-20260926/bench 2 middleout blackhole spotlights
BENCH_MIN_SECONDS=0.5 taskset -c 2 /tmp/otfx-single-pass-20260926/bench 2 unstable
```
