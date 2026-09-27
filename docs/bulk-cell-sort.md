# Append arrivals, sort once per cell

A later [five-loop, same-process comparison](five-loop-benchmark.md) covers
all 35 finite effects and confirms an approximately 2% aggregate regression.

Rejected experiment, 2026-09-26. Removed from the working tree with user
approval; its source remains in `/tmp/otfx-bulk-sort-20260926/after-src/`.
The previous
flat-stack source and binary are preserved under
`/tmp/otfx-bulk-sort-20260926/before-src/` and `before`.

Departures still use binary search and ordered removal from sorted stacks.
Arrivals append; a bitset records cells whose appended keys break ordering.
After arrivals, native `sort.quick_sort_proc` sorts each marked cell once.
The cached top is maintained during insertion so content dirtying retains
its existing behavior. No per-particle links or slot indices were added.

This isolates batched insertion: removal shifts remain. A full stack sort
can cost more than an ordered insertion when few particles arrive.

| Effect | Previous ms | Bulk-sort ms | Change |
| --- | ---: | ---: | ---: |
| Middleout | 30.2 | 29.3 | -3.0% |
| Fireworks | 79.0 | 80.3 | +1.6% |
| Expand | 25.4 | 27.2 | +7.1% |
| Swarm | 120.5 | 123.3 | +2.3% |
| Binarypath | 205.4 | 208.2 | +1.4% |
| Colorshift | 28.2 | 28.1 | -0.4% |

Six-effect arithmetic mean best wall: 81.45 -> 82.73 ms (+1.6%).
Mean child CPU: 81.37 -> 82.60 ms (+1.5%). Mean peak RSS is approximately
14.7 MiB for both. All six frame counts match. This small screen does not
establish statistical significance or a 35-effect result. It does not
justify replacing the previous implementation on performance grounds.

Validation: `odin check src` and optimized native/debug build pass.
76 tests: 72 pass, the same four existing allocation tests fail.
222/222 exact captures match the frozen previous implementation across
37 effects and six fixtures. Full 35-effect benchmark, parity tool, and
separate smoke matrix were not rerun for this preliminary screen.

Both binaries use `-o:speed -microarch:native -debug`, CPU 2, terminal
200x50, input 190x46, seed 1, frame rate zero, stdout `/dev/null`.
Two samples with a 0.3-second minimum batch. CPU is wait4 user+system;
RSS is peak across measured children. The harness's `rust` label is the
previous Odin binary, not ASM.

Artifacts under `/tmp/otfx-bulk-sort-20260926/`: `screen.log`, `tests.log`,
`capture.log`, `capture.json`, `engine.diff`, frozen `before`/`after`
binaries and source snapshots. Nothing committed; root executable unchanged.

```sh
odin build src -o:speed -microarch:native -debug -out:/tmp/otfx-bulk-sort-20260926/after
odin build bench -o:speed -define:OTFX_BENCH_BINARY=/tmp/otfx-bulk-sort-20260926/after -define:REFERENCE_BENCH_BINARY=/tmp/otfx-bulk-sort-20260926/before -out:/tmp/otfx-bulk-sort-20260926/bench
BENCH_MIN_SECONDS=0.3 taskset -c 2 /tmp/otfx-bulk-sort-20260926/bench 2 middleout fireworks expand swarm binarypath colorshift
```
