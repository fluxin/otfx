# Flat sorted cell stacks

Current flat-stack implementation, 2026-09-26. The
[bulk-sort experiment](bulk-cell-sort.md) was removed with user approval;
its source and binaries remain preserved. Aggregate performance improves,
but Middleout still regresses; this is not an unconditional acceptance.
No commits were made and the root `otfx` executable was not replaced.

Each cell owns one sorted array of eight-byte `Render_Key` values: 32-bit
particle ID and 32-bit nonnegative layer, with layer as the high half.
The limits are checked before packing. The public particle ID remains
machine-sized. Particles retain only their published cell index; the update
queue snapshots the previous layer. Nested layer arrays, particle slot
indices and their repair writes, deferred winner resolution, and the vacated
cell queue are removed.

The last entry is the visible winner. Removing it pops the stack; interior
removal uses native binary search and ordered removal. Insertion appends above
the winner, otherwise uses native binary search and `inject_at`. First-entry
checks avoid searching at the lower endpoint. Geometric capacity growth is
explicit because this Odin version's `inject_at` otherwise grows to the exact
new length. Content-only updates still bypass placement work and patch only
the visible winner. The effect API is unchanged.

## Results

Paired against the frozen change-flags binary, before the slower reverse-slot
experiment. Full results: [cell-stack.tsv](cell-stack.tsv).

| Metric | Before | Flat stack |
| --- | ---: | ---: |
| 35-effect arithmetic mean best wall | 45.000 ms | 41.583 ms |
| Mean wall | 45.129 ms | 41.769 ms |
| Mean child CPU | 44.949 ms | 41.597 ms |
| Mean per-effect peak RSS | 13,634 KiB | 12,746 KiB |
| Middleout best wall | 27.6 ms | 30.1 ms |
| Fireworks best wall | 82.6 ms | 78.9 ms |
| Expand best wall | 27.5 ms | 25.5 ms |
| Swarm best wall | 127.8 ms | 120.3 ms |

Best wall improves 7.59%, CPU 7.46%, and mean peak RSS 6.52%.
Geometric speedup is 1.081x. Middleout is the only effect over 2% slower,
at +9.1%. All 35 finite-effect frame counts match.

The latest fetched, cached ASM reference `c2be6411` remains 30.8 ms mean
best wall and 95.3 ms Swarm. Current Odin takes about 35% more aggregate time
and 26% more Swarm time; matching the aggregate requires another 26% reduction
from current Odin time. This is not a freshly paired ASM run. Whole-effect
workloads differ: Swarm has 4,312 Odin frames versus 5,041 ASM frames.
Cached ASM mean peak RSS is 50.6 MiB versus current Odin's 12.4 MiB.

An earlier exact-capacity insertion variant inflated memory and regressed
crowded effects. Geometric reserve fixed that. Profiling the geometric
variant's production Middleout attributed about 22% of sampled cycles to
binary search. Endpoint checks reduced Middleout from 30.6 to 30.1 ms across
the two screens, but did not eliminate its regression. Native quicksort or
heapsort would require a batch insertion/rebuild experiment; replacing the
search alone would not eliminate ordered shifts.

## Validation and reproduction

- Formatting, `odin check src`, and optimized native/debug build pass.
- 222/222 byte-exact captures across 37 effects and six fixtures.
- 37/37 smoke checks; parity: 13 match, 24 existing diagnostic differences,
  zero failures.
- 76 tests: 72 pass, the same four pre-existing allocation tests fail:
  `appearance_packet_survives_placement_changes`,
  `bounded_playback_reuses_build_storage`,
  `frame_composition_character_growth_is_amortized`, and
  `rebuilt_output_storage_does_not_grow`.
- Tests cover packed ordering/limits, published membership, crowded cells,
  layers through 128 and max(u32), randomized full-paint comparison, and
  amortized interior insertion growth.

Both binaries use `-o:speed -microarch:native -debug`, CPU 2, seed 1,
terminal 200x50, input 190x46, frame rate zero, stdout `/dev/null`.
Two batched samples with a 0.3-second minimum per sample; CPU is wait4
user+system, RSS maximum across measured children. Matrix and Thunderstorm
use one-second duration diagnostics and are excluded from the 35-effect mean.
Their frame counts are 5,395/5,532 and 5,174/5,174 respectively.

Artifacts: `/tmp/otfx-cell-stack-20260926/` contains frozen binaries,
`endpoints-full.log`, the TSV, validation logs, `engine.diff`, and source
snapshots. `holes-draft/` preserves the redirected holes experiment; it was
not validated or benchmarked. Earlier variants remain available.

Baseline SHA-256:
`44b793053ac36a3bf1b31d8c4ffaee7026d527f32b1014c89c5c96e579b1d189`.
Candidate (`endpoints`) SHA-256:
`4ff2fee6c48fd45c0b44a2d5417eeb99b5183ba65cc45fa607c8411d97b98df0`.

```sh
odin build src -o:speed -microarch:native -debug -out:/tmp/otfx-cell-stack-20260926/endpoints
odin build bench -o:speed -define:OTFX_BENCH_BINARY=/tmp/otfx-cell-stack-20260926/endpoints -define:REFERENCE_BENCH_BINARY=/tmp/otfx-cell-stack-20260926/pre-slots -out:/tmp/otfx-cell-stack-20260926/bench-endpoints
BENCH_MIN_SECONDS=0.3 BENCH_MATRIX_RAIN_TIME=1 BENCH_STORM_TIME=1 taskset -c 2 /tmp/otfx-cell-stack-20260926/bench-endpoints 2
```

The harness's `rust` label denotes the frozen Odin baseline in this experiment.
