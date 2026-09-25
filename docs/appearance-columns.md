# Appearance columns and character construction

This working-tree change separates prepared-code IDs from membership links in
the engine's Odin `#soa` character store. Logical appearance stays in one current
`Visual` record for both prepared and dynamic publication. `get_visual`,
`set_visual`, `set_character`, and component setters preserve the same contract.
Prepared IDs select encoded spans; callers never materialize state or invalidate
its byte cache manually. Low-level direct writers still mark their edits.

An initial experiment split symbol, foreground, background, and bold into
separate columns and made logical reads resolve prepared IDs lazily. Full-effect
measurements rejected that implementation: it regressed overall throughput and
Middleout by roughly 25%. Profiles placed most added cost inside effect loops
using the shared getter/setter. Keeping whole-value data together and one
logical authority recovered that loss without changing effect choreography.

The membership record is 12 bytes. Encoded dynamic colors remain 24 bytes with
packed length/validity fields. Existing dirty and selection bit arrays retain
ownership of invalidation; this does not introduce separate dirty planes for
each appearance field.

`set_visual_codes(e, ids, codes)` accepts ordinary slices. It compares eight IDs
at a time and skips unchanged blocks; changed blocks use the ordered scalar
setter, including repeated character IDs. Native disassembly contains 256-bit
`vpxor`/`vptest` comparisons. This is not a vectorized scatter or a claim that
whole-frame rendering has been vectorized. Colorshift and Decrypt use the shared
operation.

Input/fill populations are counted and their columns sized before initialization.
Generated populations use `character_batch(e, count)` and the overloaded
`add_character(&batch, symbol, position)`. The engine reserves character storage,
added IDs, and dirty/selection bits together. Binarypath, Burn, Laseretch, and
Thunderstorm no longer reserve the engine's internal arrays themselves. Ordinary
`add_character(e, symbol, position)` still supports incremental creation.

## Validation

- `odinfmt -w src` and `odinfmt -w tests`.
- `odin check` for `src`, `tools/accuracy`, `tools/parity`, and `tools/docs`.
- `odin build src -o:speed -microarch:native`.
- `odin test tests -o:speed -microarch:native`: 43 tests pass, including ordered
  bulk/scalar equivalence, prepared-to-dynamic edits, fixed-population
  playback allocation checks, and batched construction across dirty-bit words.
- 222/222 byte-exact captures against the shared-writer baseline: all 37 effects,
  six fixtures (plain, no color, SGR always/dynamic, xterm Unicode, clipped/wrapped),
  seed 42, frame rate 0, virtual clock, 40x12 canvas or clipped 7x3. Matrix rain
  and Thunderstorm duration are each one virtual second.

## Performance status

The performance goal remains open. Correctness and lower memory consumption
alone do not pass the shared-renderer keep gate. The final implementation is
about 2% faster overall than the prior shared-writer version, with 17% lower
mean peak RSS. Rings remains about 3% slower: the no-regression gate is open.

Both Odin binaries use `-o:speed -microarch:native`, compiler
`dev-2026-09-nightly:a2fb372`. The real-CLI harness uses dense 190x46 input on a
200x50 canvas, seed 1, frame rate 0, stdout `/dev/null`, three repeats, and a
minimum 0.3-second sample. Runs are pinned to CPU 2 and comparison workloads run
serially. Matrix and Thunderstorm are excluded from throughput aggregation.

| Metric, 35 finite effects | Prior shared writer | Final implementation |
| --- | ---: | ---: |
| Mean best wall time | 69.8 ms | 68.8 ms |
| Mean child CPU | 69.6 ms | 68.7 ms |
| Mean peak RSS | 13.6 MiB | 11.2 MiB |

Geometric wall speedup is 1.018x using the displayed per-effect timings. All 35
frame counts match. See [per-effect measurements](appearance-columns-baseline.tsv).
These are small throughput gains, not evidence for the proposed 20–30% lead over
ttfx ASM. The stable API and memory reduction do not establish that larger goal.

Local reproduction artifacts are in `/tmp/otfx-columns`: `baseline/` is the
source snapshot, `before` its native binary, `after` the final native binary,
`bench-after/bench.odin` the benchmark with paths adjusted, `compare-after` its
binary, `direct-full.txt` the raw results, and `capture.py`/`direct-capture.log`
the exact-capture procedure/results. The benchmark arguments list every finite
effect; its data and measurement procedures are unchanged from `bench/bench.odin`.
The final binary SHA256 is
`e7bc58d4c9cd3d929682468ae9b9172f03edcc1c368e49ceb8fbd714bc221dd8`;
the baseline is
`31c8077a3fb8deddeb8595d31cc94e9f0aa3b83d4f17e36cc1775eba7accd41f`.

Native `perf` profiles of Middleout and Rings are also retained in that directory.
They locate the earlier regressions primarily inside effect loops consuming the
shared appearance API. The final renderer compares existing records by reference
and copies whole effective snapshots. No per-effect timeline or RNG changes were
needed to recover the shared overhead.

## Current ttfx ASM comparison

The same final binary was measured serially against ttfx `origin/asm-zen5`,
revision `ac940f2e11c95ef7e6d9e6d0c8b37d389a4e5e75`, release build with
`TTFX_ASM=force`. Its SHA256 is
`a1788a30978f735fd716ed30f5b2279bd07b4b89bb994c47c0b9612e1dab315c`.
The benchmark settings above are unchanged; ASM runs first in each pair.

| Metric, 35 finite effects | ttfx ASM | Odin |
| --- | ---: | ---: |
| Mean best wall time | 54.6 ms | 68.8 ms |
| Mean child CPU | 54.6 ms | 68.6 ms |
| Mean peak RSS | 87.9 MiB | 11.2 MiB |

ASM remains approximately 1.37x faster by geometric mean. This is whole-CLI
throughput with different frame counts in 21/35 effects, not normalized
per-frame simulation or terminal-emulator performance. There is no demonstrated
lead over ASM. See [per-effect ASM measurements](appearance-columns-asm.tsv).
Raw output is `/tmp/otfx-columns/direct-asm.txt`; `bench-asm/bench.odin` and
`compare-asm` contain the reference-path-adjusted native harness.

## Remaining shared cost

A follow-up native profile uses 40 Colorshift CLI runs per binary, pinned to
CPU 2, the same dense input, seed 1, and frame rate 0 (`perf record -F 1999 -g`).
Both produce 528 frame markers in the benchmark. Odin self samples are about
35% in effect stepping, 20% in changed-cell emission, 12% in buffer append,
10% in frame emission, and 4% in decimal cursor formatting. These are sampled
costs for this effect, not percentages established across all effects.

The ASM source's `asm/engine/render.asm` documents and implements retained
per-row bytes, dirty-row reuse, a handle-grid emission loop, and row iovecs.
Odin still walks dirty cells and assembles a sparse output buffer using per-cell
emission and cursor placement. This is a concrete shared renderer difference
to investigate; the profile does not prove that copying ASM's row strategy will
win on sparse effects or in a real terminal. ASM's release binary is stripped,
so its sampled addresses have not been assigned function-level percentages.

Profiles: `/tmp/otfx-columns/colorshift-final.perf.data` and
`/tmp/otfx-columns/colorshift-asm-final.perf.data`; the invocation loop is
`/tmp/otfx-columns/profile-loop.sh`. Further renderer work must retain the
logical setter API and compare sparse and dense updates across the full suite.
