# Gathered particle updates

The queue is a gather: one pending `Particle_Update` per particle, not one command
per setter. `pending_indices` is a separate u32 column mapping a particle to its
one-based pending slot; zero means absent. The first changed setter appends an
entry. Later setters merge final values into it. A `bit_set[Particle_Field; u8]`
records supplied position, visibility, layer, glyph, and appearance fields.
Untouched placement fields are read from published state when applying.

Setters modify only pending values. Particle values, cell membership, prefix
encoding, and row emission remain deferred until rendering. Style comparisons
use pending values when present, otherwise published values. This preserves
shared/local assignment order and prevents an enqueue-time guard from dropping
a return to the original value. Unchanged setters without pending work do not
create entries.

Composition applies each particle's final placement once. Moving out and back,
or changing layer and restoring it before rendering, does not alter membership.
The applied logical placement identifies the old membership, so no old-cell or
old-layer snapshots are stored in updates. Glyph and style changes only notify
the final winning cell. Dirty-cell bits coalesce byte encoding; dirty appearances
remain lazy. No full-grid or full-particle scan was added. New particles are
admitted once after their pending changes apply.

`updates.odin` owns pending values and application. `Particle` has no queue flag;
the separate slot column is cleared while draining. Entries own logical values,
not pointers or encoded prefixes. Queue capacity follows particle capacity,
bounding entries to one per particle. The prior typed command union is removed.
`canvas_bytes` names the single contiguous byte allocation; rows borrow slices.
Cell storage and the once-per-loop temp allocator reset are unchanged.

The five effect adaptations from the deferred-command experiment remain:
Blackhole/Bubbles use computed positions, Overflow stages its row coordinate,
Rings passes its computed endpoint, and Matrix submits only changed fields.
Getters and previews still return last-applied values without implicit flushing.

## Validation

- Source check and optimized native debug build pass. Docs/accuracy checks,
  instrumented phase check, and source formatting pass.
- Normal and stats-enabled tests: 58/62 pass. The same four allocation tests
  remain failing: `appearance_packet_survives_placement_changes`,
  `bounded_playback_reuses_build_storage`,
  `frame_composition_character_growth_is_amortized`, and
  `rebuilt_output_storage_does_not_grow`. Counts differ; no assertions were relaxed.
- Gather regression verifies one entry for repeated setters, deferred values,
  final layer priority, covered appearance deferral, exposure, shared/local
  assignment order, slot clearing, and glyph/color round trips. A placement
  round trip emits no row and never allocates the intermediate layer.
- All 222 captures preserve terminal cells and frame counts: 211 exact streams, 11
  replayed streams with redundant-emission differences. Six fixtures, seed 42,
  virtual clock; Matrix/Thunderstorm have one-second virtual windows.
- All 37 effects pass the four-frame smoke matrix. Non-ASM Rust parity reports
  13 matches, 24 diagnostic differences, zero failures.

## Paired performance

Before is the immediate-value, deduplicated particle queue; after is the deferred
gather. Both are frozen Odin binaries using `-o:speed -microarch:native -debug`.
The full suite uses CPU 2 affinity, seed 1, terminal 200x50, input 190x46, unpaced
`/dev/null` output, three samples, minimum 0.3-second batches, and wait4 CPU/RSS.
Harness `rust` labels the before Odin binary. Matrix/Thunderstorm are separate
one-second wall-clock diagnostics, excluded from the 35-effect aggregate.
An initial overlapping run was interrupted and discarded; the reported full
suite ran after validation finished. ASM was not rerun.

```
throughput summary (35 effects, unweighted means):
  best wall 49.3ms / 50.5ms, mean CPU 49.5ms / 50.6ms, peak RSS 12.8 MiB / 13.5 MiB
  geometric wall-speedup 0.97x, Odin/Rust CPU 1.02x, Odin/Rust RSS 1.05x
```

[All 35 measurements](gathered-updates-benchmark.tsv). All frame counts match.
The earlier uncoalesced command trial measured 49.3→54.5ms best-wall means,
49.5→54.5ms CPU and 12.7→15.2MiB RSS; that is a separate experiment, not a fresh
paired comparison with the gather.

Initial best-wall regressions over 2% follow. No separate noise screen was run;
small differences are not established regressions.

| Effect | Before ms | Gather ms | Change |
|---|---:|---:|---:|
| beams | 33.1 | 34.4 | +3.9% |
| blackhole | 76.3 | 81.0 | +6.2% |
| bubbles | 74.7 | 78.9 | +5.6% |
| crumble | 57.4 | 60.0 | +4.5% |
| errorcorrect | 17.6 | 18.0 | +2.3% |
| expand | 35.9 | 37.5 | +4.5% |
| fireworks | 118.7 | 125.9 | +6.1% |
| highlight | 6.0 | 6.3 | +5.0% |
| overflow | 19.7 | 21.5 | +9.1% |
| print | 13.9 | 14.2 | +2.2% |
| randomsequence | 6.0 | 6.3 | +5.0% |
| rings | 107.6 | 111.6 | +3.7% |
| scattered | 61.0 | 62.5 | +2.5% |
| smoke | 18.2 | 18.7 | +2.7% |
| spray | 54.7 | 57.1 | +4.4% |
| swarm | 152.9 | 157.4 | +2.9% |
| sweep | 12.3 | 12.8 | +4.1% |
| synthgrid | 14.8 | 15.5 | +4.7% |
| unstable | 68.8 | 73.2 | +6.4% |
| vhstape | 39.6 | 42.3 | +6.8% |
| wipe | 8.0 | 8.5 | +6.2% |

Engine delta against immediate-value baseline: +191/-105 lines (net +86).
Against uncoalesced commands: +189/-151 lines (net +38).

The experiment remains available for review; its performance gate is judged from
the full suite, not a single-effect gain. Deferred staging still stores final
logical values separately from published particle values, so deduplication does
not remove all staging/lookup cost.

Artifacts are in `/tmp/otfx-dedup-actions-20260926/`: `before` is the measured
immediate-value baseline; `uncoalesced` preserves the command binary; `after` is
the gather. `before-src/tests` preserve the uncoalesced source, `after-src/tests`
the gather. Original baseline source is in `/tmp/otfx-actions-20260926/before-src`.
Both comparison patches and all logs/scripts are preserved. No commits were made.

SHA-256:

- before: `2ba4581156e254ac4c558bac380d904de1a1db205d76a1b152ae78c86f2a6ef3`
- uncoalesced: `b9a33ca6ff30c077ce7f22b581837ac1e837782f51dcf25e1b283216a6b23c65`
- after: `c203af6d28c79d06941a6b0617b3ea58517cf1b580a21c08077a52cc7a3c6e7f`
