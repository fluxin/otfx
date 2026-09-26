# Lazy appearance flag

Preserved grid-scan experiment, superseded by the
[deduplicated particle queue](particle-queue.md). The flag-only appearance
invalidation remains; the queue supplies targeted renderer work.

`dirty_appearance` only enables the selected appearance's `dirty` flag. It does
not check visibility, resolve coordinates, inspect ownership, or dirty cells or
rows. Style setters only update logical fields and the appearance flag.

Rendering walks cell owners and queues cells whose selected appearance is dirty.
It collects all such cells before encoding clears any shared flags. The first
cell encodes the shared 43-byte prefix; later cells copy those prepared bytes.
Ownership changes still enqueue their cells. Patching marks the row for output.

`get_render_appearance` returns a pointer to the selected initial/shared/private
appearance. Preview takes a local copy and cannot clear retained dirty state.
`Appearance.length` remains removed: styled output uses 43 bytes; plain/no-color
output omits the prefix. No particle dirty flags, update queues, generation
counters, maps, or per-particle complete packets were added.

Glyph edits and switching appearance IDs mark the same appearance flag. This is
conservative: a glyph edit can refresh other cells using its shared appearance,
and re-encode the unchanged style prefix. A shared appearance used by no top
cell stays dirty until exposed. A shared appearance also used by a top cell may
be resolved for that user; exposure later already dirties the newly owned cell.

The simpler setters trade their owner lookup for a viewport-cell scan each frame.
This experiment is retained for review; previous implementations and measurements
remain preserved. No performance acceptance claim is inferred from correctness.

## Validation

- Source, docs/accuracy tools, and instrumented phase checks pass.
- Normal and instrumented tests: 57/61 pass, the same four existing allocation
  failures. Covered/private edits, shared updates reaching multiple top cells,
  switching back to an encoded shared appearance, glyph changes, preview,
  no-color/xterm modes, and row deferral are covered.
- All 37 effects pass the four-frame smoke matrix.
- 222 capture cases preserve frame-by-frame terminal cells, glyphs, colors,
  bold, and frame counts. 182 streams are byte-identical; 40 have different
  redundant row emission and pass terminal replay. Six fixtures, seed 42,
  virtual clock; Matrix/Thunderstorm use one-second virtual windows.
- Rust non-ASM parity: 13 matches, 24 diagnostic differences, zero failures.

## Paired performance

Before is the [cell-dirty variant without Appearance.length](render-dirty.md).
Both binaries: `-o:speed -microarch:native -debug`, CPU affinity 2, seed 1,
200×50 terminal, 190×46 input, unpaced output to `/dev/null`, three samples with
0.3-second minimum batches. CPU/RSS use `wait4`; harness `rust` means before
Odin. ASM was not rerun. Matrix/Thunderstorm are excluded from the finite suite.

```
throughput summary (35 effects, unweighted means):
  best wall 49.8ms / 67.2ms, mean CPU 50.0ms / 67.7ms, peak RSS 12.4 MiB / 12.3 MiB
  geometric wall-speedup 0.72x, Odin/Rust CPU 1.35x, Odin/Rust RSS 0.99x
```

[All 35 per-effect wall/CPU/RSS and frame results](appearance-flag-benchmark.tsv).
All frame counts match. Slowdowns over 2% from this screen are listed below;
no separate per-effect noise check has been performed.

| Effect | Before ms | After ms | Change |
|---|---:|---:|---:|
| beams | 32.0 | 38.7 | +20.9% |
| binarypath | 252.9 | 278.4 | +10.1% |
| blackhole | 79.4 | 96.4 | +21.4% |
| bouncyballs | 48.1 | 97.9 | +103.5% |
| bubbles | 78.1 | 139.3 | +78.4% |
| burn | 43.4 | 69.0 | +59.0% |
| colorshift | 27.5 | 30.2 | +9.8% |
| crumble | 62.9 | 76.2 | +21.1% |
| decrypt | 34.1 | 80.1 | +134.9% |
| errorcorrect | 17.7 | 52.8 | +198.3% |
| expand | 37.0 | 39.2 | +5.9% |
| fireworks | 114.7 | 126.3 | +10.1% |
| highlight | 5.9 | 6.8 | +15.3% |
| laseretch | 58.0 | 137.3 | +136.7% |
| middleout | 30.2 | 30.9 | +2.3% |
| orbittingvolley | 33.7 | 41.8 | +24.0% |
| pour | 24.7 | 58.2 | +135.6% |
| print | 14.7 | 56.3 | +283.0% |
| rain | 24.0 | 47.5 | +97.9% |
| randomsequence | 5.8 | 9.0 | +55.2% |
| rings | 111.6 | 128.9 | +15.5% |
| scattered | 63.9 | 71.9 | +12.5% |
| slice | 14.1 | 16.1 | +14.2% |
| slide | 32.2 | 33.9 | +5.3% |
| smoke | 17.4 | 23.0 | +32.2% |
| spotlights | 50.9 | 56.1 | +10.2% |
| spray | 60.6 | 79.5 | +31.2% |
| swarm | 154.7 | 188.0 | +21.5% |
| sweep | 12.0 | 13.2 | +10.0% |
| synthgrid | 14.1 | 17.9 | +27.0% |
| unstable | 75.9 | 81.0 | +6.7% |
| vhstape | 40.0 | 42.9 | +7.3% |
| waves | 32.5 | 48.0 | +47.7% |
| wipe | 7.7 | 8.3 | +7.8% |

Engine source delta against this baseline: +17/-20 lines (net -3).

Artifacts, source snapshots, commands, binaries, logs, and scoped patch:
`/tmp/otfx-appearance-flag-20260926/`. Earlier trials remain in
`/tmp/otfx-render-dirty-20260926/` and `/tmp/otfx-appearance-bytes-20260926/`.
No commits were made.

SHA-256:

- before: `7c96d5aea6b979e7a6d31f5a144d639d2a3f3ec6ca9b68900fdde600215c2ab5`
- after: `ef2bbef3f05281d9670603c33f0e0201787351cf3bd90cf2ae3ff595094da206`
