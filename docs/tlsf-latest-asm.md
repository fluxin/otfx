# TLSF experiment and latest ASM comparison — 2026-09-26

TLSF was removed from production code with user approval after this comparison.
The experiment recycles
renderer cell layer arrays within pools backed by the existing run arena.
Its reservation policy slightly increases runtime and raises mean peak
RSS. The measured TLSF source remains in
`/tmp/otfx-tlsf-20260926/measured-src`, alongside frozen binaries. Only the
TLSF changes were reverted; no changes were committed.

## Measurements

35 finite effects, unweighted arithmetic means:

| Metric | Before TLSF | TLSF, allocator comparison | Latest ASM | TLSF, ASM comparison |
| --- | ---: | ---: | ---: | ---: |
| Best wall per effect, ms | 48.1 | 48.7 | 30.8 | 48.6 |
| Mean wall per effect, ms | 48.4 | 49.1 | 30.8 | 48.9 |
| Mean child CPU, ms | 48.2 | 48.9 | 30.7 | 48.7 |
| Mean of per-effect peak RSS, MiB | 13.1 | 15.0 | 50.6 | 15.0 |

TLSF increased best-wall arithmetic mean by 1.1%, mean CPU by 1.4%, and mean
peak RSS by 14.0%. This is no demonstrated speed benefit. The latest ASM is
1.58x faster by the ratio of arithmetic best-wall means; its geometric
per-effect speedup is 1.83x. The two TLSF columns are separate runs of the
same frozen binary, not different implementations.

Both binaries ran pinned to CPU 2 with seed 1, frame rate 0, stdout to
`/dev/null`, terminal 200x50, and dense input/default canvas 190x46. Each effect
used three batched samples with a 0.3-second minimum per sample. CPU and RSS
come from `wait4`. No build, test, or profiling job ran alongside measurements.
Matrix and Thunderstorm used one-second configured windows and are excluded
from the aggregate.

Odin binaries use `-o:speed -microarch:native -debug`. ASM is a release build
of fetched `asm-zen5` revision `c2be6411`, built offline in
`/tmp/ttfx-asm-c2be6411`; `TTFX_ASM=force` prevents Rust fallback. A separate
startup check reported ASM tier 4. Its unpaced render thread shares the same
CPU affinity as the main thread, so this is a one-core comparison.

All 35 finite-effect frame counts match before/after TLSF. ASM and Odin have
different choreography/frame counts in 21 of 35 effects; these are full-effect
completion timings, not equal-frame throughput. Matching-frame examples:
Expand 16.6/35.6 ms and Wipe 2.8/8.2 ms (ASM/TLSF). Laseretch is nearly tied
at 59.3/59.5 ms with 14,306/14,307 frame markers.

Full results, including CPU, RSS, frame counts, and individual regressions:

- [TLSF versus before](tlsf-benchmark.tsv): reference is before, candidate is TLSF.
- [Latest ASM versus TLSF](tlsf-latest-asm-benchmark.tsv): reference is ASM, candidate is TLSF.

Before/TLSF effects over 2% slower in the initial screen were Blackhole,
Errorcorrect, Middleout, Orbittingvolley, Overflow, Print, Randomsequence,
Slide, Smoke, Synthgrid, VHStape, and Wipe. These are screening measurements,
not individually confirmed regressions beyond noise. Middleout was +9.0%
and Overflow +5.2%. Binarypath peak RSS rose from 20,840 to 37,408 KiB;
Blackhole fell from 15,092 to 13,044 KiB. Pool reservation is not uniformly
better than arena allocation.

## Correctness and allocation status

The full 222-capture matrix is byte-identical to the frozen before binary.
The TLSF unit-test result was 63/64: the bounded-playback test still sees
two extra backing allocations during Blackhole. Three of the four original
allocation failures now pass. No allocation assertion was weakened.

The test runner supplies Xoshiro256, unlike the standalone diagnostic's
default generator. Resetting each to seed 42 does not produce the same
movement pattern. Repeating the diagnostic with the test runner's generator
reproduces Blackhole's extra pool growth. TLSF still services internal logical
allocation requests even where backing-allocation counters stay unchanged;
this is not a claim of zero allocation work.

The control object has a stable address because TLSF retains self-pointers;
the enclosing Engine may move by value. The run arena owns control and pool
lifetime. Particle-capacity growth currently reserves renderer capacity with
a temporary TLSF allocation/free; unusually crowded or high-layer cells can
still grow pools. The remaining allocation failure and extra memory use need
resolution before this experiment can be considered complete.

## Similarities in the newly fetched ASM

The range `ac940f2e..c2be6411` adds techniques also present in our work:
per-frame change records (`891e49e`), reuse of previously encoded row bytes
(`4c93c2a`), dirty four-cell blocks and 64-cell summaries (`2907fe4`,
`abf5b2a`), bulk input publication (`d361101`), and paired-axis interpolation
(`6df95a8`). These are architectural similarities, not evidence of copying.
The prior ASM already retained row bytes and wrote appearance changes through
to its owner grid.

Their implementation differs: ordered operation logs feed a render thread;
occupants use per-particle intrusive links; variable-length packed row bytes
use double buffers and block offsets. We deduplicate particle updates and use
per-cell layer arrays with fixed-width padded cell slots. Searches of the new
commit messages and ASM/source/plans/README found no `otfx` or `Odin`
attribution. Source comparison cannot establish whether our design influenced
the work.

## Reproduction and retained artifacts

```sh
BENCH_MIN_SECONDS=0.3 BENCH_MATRIX_RAIN_TIME=1 BENCH_STORM_TIME=1 \
  taskset -c 2 /tmp/otfx-tlsf-20260926/bench 3
TTFX_ASM=force BENCH_MIN_SECONDS=0.3 BENCH_MATRIX_RAIN_TIME=1 BENCH_STORM_TIME=1 \
  taskset -c 2 /tmp/otfx-latest-asm-20260926/bench-tlsf 3
UV_CACHE_DIR=/tmp/uv-cache uv run python /tmp/otfx-tlsf-20260926/capture.py
```

Frozen binaries (SHA-256):

- Before `/tmp/otfx-tlsf-20260926/before`: `6504073f0ebc98138a1472edd13a112cee4678c3be7135f33b1ab81e82c5b391`
- TLSF `/tmp/otfx-tlsf-20260926/after`: `7f97e4e70b3cf1ceecbfd5848968cf5e90ddeff7dd908faf806a78b5bad82f4b`
- ASM `/tmp/ttfx-asm-c2be6411/target/release/ttfx`: `ae0cf2e8a62c208b42f78cee60d9d4c948ac9c07145a83a96aef6235934a7171`

Raw logs and capture JSON are beside the binaries. The benchmark harness's
`rust`/`odin` labels mean reference/candidate; in the allocator comparison
both are Odin builds. Source snapshots preceding TLSF are retained alongside
the before binary.
