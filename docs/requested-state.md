# Requested particle state and deferred publication

Particles hold requested values directly. Every setter compares and assigns that
value immediately, so getters and previews observe it immediately. Before the
first change, `queue_particle` snapshots the published cell/layer and enqueues the
particle once. Later setters overwrite the same requested state without adding
entries. The particle itself gathers the final values.

The renderer owns publication. A queue entry is only 24 bytes:
`{id, previous_cell, previous_layer}`. One `update_queued` boolean in the particle
SoA deduplicates entries. New particles are admitted once and need no entry before
their first composition. Queue capacity follows particle capacity.

Composition removes changed old memberships in one pass, then inserts final
placements in another. Removing first prevents a cached cell winner from being
compared against another queued particle's requested, unpublished layer. Each
particle's final placement is reconciled once; intermediate moves/hides/layers
are never inserted. Glyph/style changes leave membership intact and only final
winning cells are patched. The queue and flags are cleared afterward.

The deferred gather's duplicated glyph/placement/appearance values, field mask,
u32 slot-index table, pending style resolver, and field-by-field application are
removed. `updates.odin` is removed; the small publication entry/helper live with
composition in `render.odin`. Glyph/placement setters remain in `particle.odin`,
appearance setters in `codes.odin`.

Appearance fields change immediately, but `dirty_appearance` remains just a flag.
Encoding remains lazy in the dirty-cell loop; covered/private prefixes wait until
exposed. Shared styles still require explicit notification of their consumers:
mark shared prefix dirty and call `set_appearance` with its ID for each consumer.
Selecting that same ID queues publication when the shared prefix is dirty.
There is no appearance broadcast scan or eager row dirtying.

`canvas_bytes` remains the contiguous allocation borrowed by rows. Setters do not
change it or the completed output. Previewing a particle uses requested values
and a local encoded copy. Temp allocator resets remain once at the playback-loop
boundary. Effect adaptations from the gather experiment remain, with Blackhole's
comment updated to describe computed positions without deferred-value assumptions.

## Validation

- Source check, optimized native debug build, formatting, docs/accuracy checks,
  and instrumented phase check pass.
- Normal and stats-enabled tests: 58/62 pass. Four existing allocation tests still
  fail: `appearance_packet_survives_placement_changes`,
  `bounded_playback_reuses_build_storage`,
  `frame_composition_character_growth_is_amortized`, and
  `rebuilt_output_storage_does_not_grow`. Counts differ; allocation assertions
  remain unchanged. Allocation-free playback is not claimed.
- Publication regression verifies immediate requested getters, unchanged cell
  ownership and completed bytes before rendering, one entry per particle, final
  collision/layer priority, covered prefix deferral, exposure, shared/local edit
  order, and queue clearing. Movement/layer round trips do not create intermediate
  membership. The gather-specific assertion of no redundant row output was
  replaced with membership invariants: this simpler queue may repatch its final
  winner because it stores no separate appearance-change mask.
- Thunderstorm's effect-state test no longer needs to drain values before reading.
- All 222 captures preserve terminal cells and frame counts against the frozen
  gather: 214 exact streams and 8 replayed streams with redundant-emission
  differences. Six fixtures, seed 42, virtual clock; Matrix/Thunderstorm use
  one-second virtual windows.
- All 37 effects pass the four-frame smoke matrix. Non-ASM Rust parity reports
  13 matches, 24 diagnostic differences, zero failures.

## Paired full-suite performance

Both comparisons use frozen Odin binaries built with
`-o:speed -microarch:native -debug`: affinity CPU 2, seed 1, terminal 200x50,
input 190x46, unpaced output to `/dev/null`, three samples, minimum 0.3-second
batches. CPU/RSS use wait4. Harness `rust` labels the before Odin binary.
Matrix/Thunderstorm use separate one-second wall-clock diagnostics and are
excluded from the 35-effect throughput aggregate. Validation/builds finished
before timing; the two suites ran sequentially. ASM was not rerun.

Against the frozen deferred gather:

```
throughput summary (35 effects, unweighted means):
  best wall 50.4ms / 48.8ms, mean CPU 50.5ms / 48.9ms, peak RSS 13.5 MiB / 12.7 MiB
  geometric wall-speedup 1.04x, Odin/Rust CPU 0.97x, Odin/Rust RSS 0.95x
```

[All 35 gather comparisons](requested-state-benchmark.tsv).

Against the earlier immediate-value particle queue (the roughly 49.3 ms baseline):

```
throughput summary (35 effects, unweighted means):
  best wall 49.3ms / 48.8ms, mean CPU 49.4ms / 48.9ms, peak RSS 12.7 MiB / 12.8 MiB
  geometric wall-speedup 1.01x, Odin/Rust CPU 0.99x, Odin/Rust RSS 1.00x
```

[All 35 original-baseline comparisons](requested-state-reference-benchmark.tsv).
All 35 frame counts match in both comparisons. Initial best-wall slowdowns over
2% follow; small differences have no independent noise screen.

| Comparison | Effect | Before ms | Requested ms | Change |
|---|---|---:|---:|---:|
| Gather | None | | | |
| Original | spray | 54.7 | 57.0 | +4.2% |

Engine delta against the gather: +100/-186 lines (net -86).

Source/test/docs snapshots, frozen binaries, captures, benchmark logs, scripts,
and scoped patch are in `/tmp/otfx-requested-state-20260926/`. `before` is the
gather, `reference` the earlier immediate-value queue, and `after` the requested
state implementation. Earlier experiments remain preserved. No commits were made.

SHA-256:

- before: `c203af6d28c79d06941a6b0617b3ea58517cf1b580a21c08077a52cc7a3c6e7f`
- reference: `2ba4581156e254ac4c558bac380d904de1a1db205d76a1b152ae78c86f2a6ef3`
- after: `0c4320678f6546c24b2cbe25dc3036cfdf822dfd15b27f0f43944694f6cdd68b`
