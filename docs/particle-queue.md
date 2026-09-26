# Queued particle updates

All glyph, appearance, position, visibility, and layer setters update logical
particle data and enqueue that particle once. `Particle.update_queued` deduplicates
repeated setters; `Engine.updates` holds contiguous 24-byte entries containing
ID, previous cell, and previous layer. The first edit records published placement.
Subsequent edits coalesce into the final particle state, without cell-list or row
mutation in setters. Queue capacity is reserved with particle capacity.

Rendering first removes changed old memberships, then inserts final placements.
Removing all old memberships before inserting avoids comparing a cached winner
against another queued particle's already-mutated layer. Appearance-only changes
do not remove/reinsert membership. Only changed particles that win their final
cell dirty its bytes. New particles are published once and need no queue entry
before first composition. No full-cell or full-particle scan remains.

`dirty_appearance(^Appearance)` is exactly a flag assignment. Style setters
invalidate the prefix and queue the particle; glyph changes and switching to an
existing appearance ID only queue the particle. The dirty-cell loop lazily
encodes prefixes and clears their flags; all queued cells still patch even when
a shared prefix was already encoded by an earlier cell. `Appearance.length`
remains removed. Rows become dirty only when their cell bytes are patched.

Shared styles are explicit: normal particle setters detach private style edits.
For direct shared-storage edits, the caller must mark that appearance dirty and
queue all affected particles; the appearance flag alone does not broadcast work.
Temporary allocator resets remain at their existing playback-loop boundary.

## Validation

- Source, docs/accuracy tools, and instrumented phase checks pass.
- Normal and instrumented tests: 58/62 pass; the same four pre-existing allocation
  test names still fail. No assertions were relaxed. Their counts shift with
  queue reservation and coalesced placement; bounded playback is not declared fixed.
- New queue regression covers repeated glyph/style/movement edits, old-cell
  erasure, colliding layer changes, covered appearance deferral, exposure, and
  visibility/clipping round trips without duplicate memberships. Shared-prefix
  tests distinguish byte invalidation from explicit particle notification.
- All 37 effects pass the four-frame smoke matrix.
- 222 captures preserve frame-by-frame terminal cells, glyphs, colors, bold and
  frame counts against the scan binary: 90 byte-identical streams and 132 replayed
  streams with changed redundant row emission. Six fixtures, seed 42, virtual
  clock; Matrix/Thunderstorm use one-second virtual windows.
- Rust non-ASM parity: 13 matches, 24 diagnostic differences, zero failures.

## Paired performance

Both comparisons use frozen Odin binaries with `-o:speed -microarch:native -debug`,
CPU affinity 2, seed 1, 200×50 terminal, 190×46 input, unpaced `/dev/null` output,
three samples and 0.3-second minimum batches. CPU/RSS use `wait4`; harness `rust`
means the before Odin binary. ASM was not rerun. Matrix and Thunderstorm are
excluded from finite-effect throughput. Validation/builds were completed before
measurement; the two full-suite comparisons ran sequentially.

Against the earlier targeted renderer (before the grid-scan regression):

```
throughput summary (35 effects, unweighted means):
  best wall 49.7ms / 49.3ms, mean CPU 50.0ms / 49.4ms, peak RSS 12.4 MiB / 12.7 MiB
  geometric wall-speedup 1.01x, Odin/Rust CPU 0.99x, Odin/Rust RSS 1.03x
```

[Full per-effect targeted-renderer comparison](particle-queue-target-benchmark.tsv).

Against the immediately preceding grid-scan implementation:

```
throughput summary (35 effects, unweighted means):
  best wall 67.0ms / 49.3ms, mean CPU 67.2ms / 49.5ms, peak RSS 12.3 MiB / 12.7 MiB
  geometric wall-speedup 1.39x, Odin/Rust CPU 0.74x, Odin/Rust RSS 1.03x
```

[Full per-effect grid-scan comparison](particle-queue-scan-benchmark.tsv).
All 35 frame counts match in both comparisons. Initial slowdowns over 2% against
the earlier targeted renderer are listed below; no separate noise screen has
been performed for these effects.

| Effect | Earlier ms | Queue ms | Change |
|---|---:|---:|---:|
| beams | 32.1 | 33.2 | +3.4% |
| burn | 43.6 | 46.2 | +6.0% |
| colorshift | 27.7 | 34.9 | +26.0% |
| decrypt | 34.1 | 37.0 | +8.5% |
| fireworks | 114.3 | 118.9 | +4.0% |
| laseretch | 58.2 | 59.7 | +2.6% |
| middleout | 30.2 | 31.2 | +3.3% |
| pour | 24.7 | 25.5 | +3.2% |
| randomsequence | 5.8 | 6.0 | +3.4% |
| smoke | 17.4 | 18.2 | +4.6% |
| spotlights | 51.0 | 52.6 | +3.1% |
| synthgrid | 14.1 | 14.8 | +5.0% |
| waves | 33.3 | 37.1 | +11.4% |
| wipe | 7.7 | 8.0 | +3.9% |

Engine source delta against the scan snapshot: +61/-69 lines (net -8).

Artifacts, source snapshots, binaries, scripts, logs, and scoped patch:
`/tmp/otfx-particle-queue-20260926/`. `before` is the scan version, `target` the
earlier targeted version, and `after` the queued version. Earlier experiments
remain preserved. No commits were made.

SHA-256:

- before: `ef2bbef3f05281d9670603c33f0e0201787351cf3bd90cf2ae3ff595094da206`
- target: `7c96d5aea6b979e7a6d31f5a144d639d2a3f3ec6ca9b68900fdde600215c2ab5`
- after: `2ba4581156e254ac4c558bac380d904de1a1db205d76a1b152ae78c86f2a6ef3`
