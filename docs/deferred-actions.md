# Deferred particle commands experiment

Setters append typed, owned values to `Engine.actions`. Logical particle values
and renderer membership change only when `compose_frame` drains the commands in
FIFO order. Equality guards run during application, so returning to the original
value within one frame is preserved. Getters and previews read last-applied values;
they never flush implicitly. Commands use an Odin value union, not reflection or
pointers into temporary storage. Appearance commands carry colors/bold, not cached
prefix bytes.

This removes the per-particle `update_queued` flag, old-cell/layer snapshots, and
two-pass membership reconciliation. Each applied placement removes old membership
before changing the particle and inserting its new membership. Dirty cell bits
still coalesce byte encoding; intermediate placements themselves are not coalesced.
The queue initially reserves particle capacity and grows if more actions are needed.
This does not establish allocation-free playback.

`dirty_appearance` remains one flag assignment. Applied style actions invalidate
prefix bytes and notify only winning cells. Encoding remains lazy in the dirty-cell
loop. No grid scan, appearance map, or row-dirty work was added to setters.
`cell_bytes` is renamed `canvas_bytes`: one contiguous allocation, with row slices
borrowing it. Cell storage/layout and the once-per-loop temp allocator reset remain
unchanged.

Five effects had same-step reads after setters. Blackhole now uses its submitted
ring position for collapse; Bubbles uses its computed anchor for landing/pop;
Overflow stages one row coordinate; Rings passes its computed endpoint into the
next path; Matrix submits only changed fields rather than resubmitting stale ones.
Effect phase tests now render each produced frame before inspecting particle data.

## Validation

- `odinfmt src -w`, `odin check src`, optimized native debug build, docs/accuracy
  checks, and instrumented phase check pass.
- Normal and stats-enabled tests: 58/62 pass. The same four allocation test names
  fail: `appearance_packet_survives_placement_changes`,
  `bounded_playback_reuses_build_storage`,
  `frame_composition_character_growth_is_amortized`, and
  `rebuilt_output_storage_does_not_grow`. Counts are not unchanged; no allocation
  assertions were relaxed.
- Command regression checks values remain unapplied before draining, FIFO return
  to original glyph/color, colliding layer changes, old-cell erasure, covered
  appearance deferral, exposure, and no duplicate membership after a round trip.
- All 222 captures preserve terminal cells and frame counts: 213 exact streams, 9
  replayed streams differing only in redundant row emission. Six fixtures, seed42,
  virtual clock, one-second Matrix/Thunderstorm windows.
- All 37 effects pass four-frame smoke. Rust non-ASM parity reports 13 matches,
  24 diagnostic differences, zero failures.

## Paired performance

Frozen Odin binaries use `-o:speed -microarch:native -debug`, affinity CPU 2,
seed 1, terminal 200x50, input 190x46, unpaced output to `/dev/null`, three samples,
and minimum 0.3-second batches. CPU/RSS come from `wait4`. Harness `rust` labels
the before Odin binary. Matrix/Thunderstorm are separate wall-clock diagnostics
with one-second windows, excluded from the 35-effect aggregate. Builds and other
validation did not run concurrently with measurement. ASM was not rerun.

```
throughput summary (35 effects, unweighted means):
  best wall 49.3ms / 54.5ms, mean CPU 49.5ms / 54.5ms, peak RSS 12.7 MiB / 15.2 MiB
  geometric wall-speedup 0.91x, Odin/Rust CPU 1.10x, Odin/Rust RSS 1.20x
```

[All 35 per-effect measurements](deferred-actions-benchmark.tsv).
All 35 frame counts match. Initial best-wall regressions over 2% follow; no
separate noise screen was run, so small differences are not established regressions.

| Effect | Before ms | Actions ms | Change |
|---|---:|---:|---:|
| beams | 33.2 | 34.8 | +4.8% |
| blackhole | 76.8 | 113.0 | +47.1% |
| bouncyballs | 48.1 | 50.1 | +4.2% |
| bubbles | 74.7 | 92.6 | +24.0% |
| burn | 46.5 | 48.1 | +3.4% |
| crumble | 57.3 | 66.6 | +16.2% |
| decrypt | 37.0 | 46.2 | +24.9% |
| errorcorrect | 17.7 | 19.2 | +8.5% |
| expand | 35.9 | 44.0 | +22.6% |
| fireworks | 118.3 | 155.9 | +31.8% |
| highlight | 6.0 | 6.5 | +8.3% |
| laseretch | 59.7 | 63.3 | +6.0% |
| overflow | 19.7 | 28.0 | +42.1% |
| rain | 23.8 | 26.6 | +11.8% |
| randomsequence | 6.0 | 6.6 | +10.0% |
| slice | 13.6 | 16.6 | +22.1% |
| slide | 30.6 | 31.3 | +2.3% |
| spotlights | 52.6 | 57.6 | +9.5% |
| spray | 54.8 | 89.2 | +62.8% |
| swarm | 153.2 | 168.3 | +9.9% |
| sweep | 12.4 | 13.2 | +6.5% |
| unstable | 69.4 | 82.9 | +19.5% |
| vhstape | 39.6 | 40.4 | +2.0% |
| waves | 36.9 | 39.0 | +5.7% |
| wipe | 8.0 | 8.6 | +7.5% |

Engine delta relative to the particle-queue snapshot: +147/-99 lines (net +48).

This is a preserved experiment, not an accepted performance improvement. The typed
queue makes publication explicit but retains intermediate placement work and stores
each setter call. The previous queue coalesced changes into final particle state.
The benchmark measures the complete change, including the five effect adaptations;
it does not isolate command dispatch from extra membership work.

Before/after binaries, source/test snapshots, logs, scripts, and scoped patch live
in `/tmp/otfx-actions-20260926/`. The earlier particle-queue and grid-scan variants
remain preserved. No commits were made.

SHA-256:

- before: `2ba4581156e254ac4c558bac380d904de1a1db205d76a1b152ae78c86f2a6ef3`
- after: `b9a33ca6ff30c077ce7f22b581837ac1e837782f51dcf25e1b283216a6b23c65`
