# Current single-core renderer: integrated lists and ID-only updates

2026-09-27. The intrusive-list prototype is now applied to the working tree,
with the user's approval. The implementation remains single-threaded. A later
terminal-output worker experiment remains isolated and is not part of this change.

## Current result against ASM

The final optimized working-tree binary is compared directly with the frozen
ASM oracle in a fresh full 35-effect run. Arithmetic mean wall is **28.534 ms
versus 30.900 ms: 7.7% lower**. The geometric OTFX/ASM time ratio is **1.0059**:
OTFX is **0.6% slower**, essentially tied at this sampling depth. These different
aggregates must not be presented as a uniform speed advantage. OTFX wins
**16/35 effects**. Small differences are not significance claims.

| Unweighted mean across 35 effects | OTFX | ttfx ASM |
|---|---:|---:|
| Mean wall per effect | 28.534 ms | 30.900 ms |
| Best wall per effect | 28.489 ms | 30.837 ms |
| Mean child CPU | 28.397 ms | 30.737 ms |
| Mean per-effect maximum RSS | 11.909 MiB | 50.716 MiB |

[All wall/CPU/RSS/frame measurements](intrusive-main-final-asm.tsv).
The following table uses mean wall. Negative change means OTFX takes less time.
Frame counts differ for **21/35** effects; these are complete-animation costs,
not equal-frame throughput. The renderer change preserves Odin's own captures
and frame counts. Existing reference RNG/choreography differences remain.

| Effect | OTFX ms | ASM ms | OTFX time change | Frames OTFX / ASM |
|---|---:|---:|---:|---:|
| beams | 13.4 | 11.7 | +14.5% | 890 / 732 |
| binarypath | 154.7 | 184.0 | -15.9% | 1932 / 1891 |
| blackhole | 50.4 | 55.3 | -8.9% | 1743 / 1800 |
| bouncyballs | 32.4 | 29.6 | +9.5% | 10393 / 9093 |
| bubbles | 47.5 | 47.0 | +1.1% | 11658 / 11742 |
| burn | 21.4 | 25.7 | -16.7% | 3237 / 3175 |
| colorshift | 16.5 | 17.2 | -4.1% | 528 / 528 |
| crumble | 37.2 | 49.7 | -25.2% | 2159 / 1835 |
| decrypt | 23.7 | 16.9 | +40.2% | 5480 / 5438 |
| errorcorrect | 12.0 | 22.4 | -46.4% | 5221 / 5237 |
| expand | 17.5 | 16.6 | +5.4% | 302 / 302 |
| fireworks | 51.1 | 63.0 | -18.9% | 1516 / 1553 |
| highlight | 3.3 | 2.8 | +17.9% | 129 / 129 |
| laseretch | 43.7 | 59.3 | -26.3% | 14307 / 14306 |
| middleout | 7.6 | 8.5 | -10.6% | 235 / 235 |
| orbittingvolley | 18.1 | 17.5 | +3.4% | 1156 / 1156 |
| overflow | 10.9 | 12.2 | -10.7% | 164 / 306 |
| pour | 16.4 | 16.9 | -3.0% | 7160 / 7160 |
| print | 6.8 | 6.7 | +1.5% | 10057 / 10057 |
| rain | 16.4 | 19.2 | -14.6% | 4736 / 4737 |
| randomsequence | 3.8 | 3.7 | +2.7% | 208 / 208 |
| rings | 73.6 | 104.5 | -29.6% | 1566 / 1566 |
| scattered | 29.3 | 25.0 | +17.2% | 420 / 418 |
| slice | 5.4 | 6.6 | -18.2% | 368 / 368 |
| slide | 18.1 | 12.8 | +41.4% | 375 / 375 |
| smoke | 13.2 | 9.7 | +36.1% | 630 / 565 |
| spotlights | 30.7 | 26.6 | +15.4% | 780 / 800 |
| spray | 23.8 | 27.0 | -11.9% | 1253 / 661 |
| swarm | 101.5 | 95.9 | +5.8% | 4312 / 5041 |
| sweep | 4.8 | 4.2 | +14.3% | 220 / 220 |
| synthgrid | 8.2 | 5.1 | +60.8% | 617 / 619 |
| unstable | 33.2 | 35.3 | -5.9% | 592 / 530 |
| vhstape | 27.2 | 24.3 | +11.9% | 726 / 736 |
| waves | 20.7 | 15.8 | +31.0% | 633 / 633 |
| wipe | 4.2 | 2.8 | +50.0% | 138 / 138 |

## What changed and what was removed

- Each particle has one stable, renderer-owned intrusive-list node carrying its
  published `(layer, ID)` key. A cell holds a list, cached winner, two state
  flags, and its existing borrowed byte slice. Cells shrink 64 to 40 bytes;
  nodes cost 24 bytes per particle.
- Covered departures unlink directly. Ordered winner departures expose the
  tail. Unordered winner departures queue a single gather/sort/relink after
  all particle updates. Per-cell dynamic stacks, membership searches, insertion
  shifts, tombstones and compaction are gone.
- The legacy `Particle_Update {id, previous_layer}` record is removed.
  `updates` is now `[dynamic]Particle_Id`: **4 rather than 16 bytes per entry**.
  Requested data stays on the particle; published layer stays on its node.
  Existing change flags deduplicate IDs and distinguish placement/content.
- `compose_frame` no longer returns canvas dimensions. Production discarded
  them; the shared diagnostic helper now reads the existing layout/rows.
- Public effect setters, particle IDs/layer limits, row bytes, dirty-cell/row
  tracking, output order, and once-per-loop temporary allocator reset are intact.
  The sort scratch and `needs_resolve` state remain necessary for deferred
  winner resolution; they are not replaced with another renderer path.

Source changes: `src/engine/render.odin`, `engine.odin`, `particle.odin`,
the automatic preparation call in `src/effects/effect.odin`, and
`tools/common/run.odin`. Tests adapt storage inspections and queue element access;
the new intrusive-cell regression verifies stable addresses and membership.
`render.odin` is 232 lines at the checkpoint, 254 in the prototype, and 247 after
cleanup. This simplifies ownership and removes paths, but is not a net renderer
line-count reduction against the checkpoint.

## Isolated attribution

A fresh [full before/list comparison](intrusive-main-full.tsv), before queue
cleanup, measured mean wall **30.417 → 28.940 ms**
(-4.86%), geometric time
**-5.20%**, and unchanged frames in all 35 effects.
Reported increases in that sweep: overflow (+1.8%), slide (+4.6%), spray (+0.4%).
The earlier [prototype reversed-order checks](intrusive-lazy-stack.md) confirmed
Slide and the small Smoke/Overflow tradeoffs. The user accepted applying the
aggregate improvement with those disclosed costs.

The [eight-effect queue-cleanup comparison](intrusive-main-cleanup.tsv) isolates
ID-only updates and removal of the dimension returns. Mean wall changes
**39.850 → 39.413 ms**;
geometric time improves **1.53%**. Seven effects improve;
Blackhole changes 49.9→50.3 ms (+0.8%, not an established regression).
Frames match throughout. The final full ASM table above includes this cleanup.
These separate samples are not multiplied together to manufacture a speedup.

## Validation

- `odin check src`, native optimized debug build, and **87/87 unit tests pass**
  both after integration and after cleanup. Four baseline playback-allocation
  failures now pass without disabling their assertions. The two pre-existing
  assertion-test arena leak warnings remain.
- **756/756 byte-identical captures** against the frozen checkpoint binary:
  222 standard cases plus 534 option/seed/color cases. This includes Unicode,
  clipping, existing colors, no-color, and virtual-clock weather.
- Full 37-effect smoke matrix; local Rust parity reports **13 frame matches,
  24 diagnostic differences, zero failures**. The parity reference is separate
  from the frozen ASM performance oracle.
- Test oracles retain independent maximum-key winner and full-paint checks,
  unique membership, predecessor/tail consistency, ordered-list claims,
  capacity reuse, and covered removal/re-entry during population growth.

Matrix and Thunderstorm remain outside the finite-effect aggregate. Separate
virtual-clock diagnostics use one logical second, the same seed/input, and
three samples of at least 0.3 seconds. Before means checkpoint; after means
final cleaned working tree. These do not measure paced terminal CPU duty.

| Effect | Before / after wall ms | Before / after CPU ms | Before / after peak RSS KiB | Frames both |
|---|---:|---:|---:|---:|
| Matrix | 63.0 / 61.0 | 62.7 / 60.7 | 10444 / 9912 | 1297 |
| Thunderstorm | 4.3 / 4.1 | 4.2 / 4.0 | 11924 / 11448 | 251 |

## Protocol and reproducibility

Ryzen 9 9900X3D, CPU 2, one core. Odin uses
`-o:speed -microarch:native -debug`, assertions enabled and the existing scoped
bounds-check exclusions. Seed 1, terminal 200×50, dense input/default canvas
190×46, frame rate 0, stdout `/dev/null`. Whole CLI construction, effect build,
playback and teardown are included. Three batched samples per binary/effect,
minimum 0.3 seconds, reference first. CPU and maximum child RSS come from
`wait4`. No own compilation, tests, captures, or other benchmark ran concurrently
with these timings. Terminal-emulator cost is excluded.

The ASM oracle was neither fetched nor rebuilt: revision
`c2be6411d3e4d5002f160dc0cbd10af7cb3a3889`, SHA256
`ae0cf2e8a62c208b42f78cee60d9d4c948ac9c07145a83a96aef6235934a7171`.
`TTFX_ASM=force` selects its assembly engine.

```sh
odin build src -o:speed -microarch:native -debug -out:/tmp/otfx-current
odin build bench -o:speed -define:OTFX_BENCH_BINARY=/tmp/otfx-current -define:REFERENCE_BENCH_BINARY=/tmp/ttfx-asm-c2be6411/target/release/ttfx -out:/tmp/otfx-current-bench
TTFX_ASM=force BENCH_MIN_SECONDS=0.3 taskset -c 2 /tmp/otfx-current-bench 3
```

The no-effect command includes separate timing-gated diagnostics; the published
35-effect run selected only finite effects. Full selected-effect invocations are
preserved in `run.py` and `run-final.py` under
`/tmp/otfx-intrusive-main-20260927/`, alongside frozen binaries, logs, capture
JSON, and `results.json`. Previous experiments remain in their original `/tmp`
directories. Source backups preserve both the checkpoint and pre-cleanup versions.

```text
checkpoint 80b04054f4ca71f123d874b69c0d7ebe52190fa9ba65f283348e2fef1bfac0a8
list-only  baacc53d390fe94b62350a863e919131205e1e5b3b120f6ecc8e2edee2795a10
final      2f70e767428199e5d8e5c323842c097a2be2d5f0e5ba88be858d444b070cc084
```

## Deferred output-worker experiment

The user chose to retain single-core execution. The bounded two-buffer terminal
writer prototype remains at `/tmp/otfx-output-worker-20260927/`; no threaded
code enters production. Its six-effect two-core screen completed, but no full
capture or acceptance gate was run, so it establishes no accepted alternative.
