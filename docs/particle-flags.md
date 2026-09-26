# Packed particle flags and requested state

Particles now store `flags: bit_set[Particle_Flag; u8]` with four bits:
`Visible`, `Fill`, `Update_Queued`, and `Preserve_Initial_Colors`. All engine,
effect, and test accesses use membership checks and individual `+=`/`-=` updates.
Visibility changes preserve queued publication and policy bits; clearing the
queue bit preserves visibility and classification. Overflow copies only the
initial-color policy to a newly created particle, not visibility or queue state.

Visibility, fill classification, and initial-color policy belong to particle
state. The queue bit is renderer-owned bookkeeping, stored in the same byte to
avoid a separate array and its allocation/growth/cleanup. SoA provides contiguous
columns; it does not automatically pack separate boolean columns into bits.

Fields use natural alignment, largest first: coordinates/layer (8-byte), IDs and
glyphs (4-byte), then appearance data and flags (1-byte). No `#packed` unaligned
struct or raw-pointer access was introduced.

| Measured storage | Before | Packed flags |
|---|---:|---:|
| `size_of(Particle)` | 128 B | 112 B |
| `align_of(Particle)` | 8 B | 8 B |
| SoA dynamic-array header | 128 B | 104 B |
| Column payload per capacity slot | 113 B | 110 B |
| Allocated SoA buffer at 10,000 slots | 1,130,000 B | 1,100,000 B |

The actual SoA saving is three bytes per capacity slot, plus fewer column headers
and alignment boundaries. The 16-byte standalone struct reduction is not a
16-byte saving per SoA slot. `sizes.odin` measures allocation through Odin's
tracking allocator against the preserved old particle type.

The requested-state simplification remains: setters update particle values
immediately and enqueue each published particle once. Its 24-byte queue entry
holds only ID and old cell/layer. Rendering removes changed old memberships
before inserting final placements, then patches winning cells. There is no
pending-value duplicate, field-mask dispatcher, or pending-index table.
`dirty_appearance` remains one lazy prefix flag. Canvas bytes and cell ownership
stay unchanged until rendering. The temporary allocator still resets once at
the playback-loop boundary.

## Validation

- Source check, formatting, optimized native debug build, docs/accuracy checks,
  and instrumented phase check pass.
- Normal and instrumented tests: 59/63 pass. The same four existing allocation
  tests fail: `appearance_packet_survives_placement_changes`,
  `bounded_playback_reuses_build_storage`,
  `frame_composition_character_growth_is_amortized`, and
  `rebuilt_output_storage_does_not_grow`. Allocation assertions were not relaxed.
- The new flag regression checks independent bits through visibility changes,
  repeated setters, queue publication, and combined placement changes.
- All 222 captures are byte-identical against the requested-state binary with
  separate booleans. Six fixtures, seed 42, virtual clock; one-second windows
  for Matrix/Thunderstorm. Frame counts are preserved.
- All 37 effects pass smoke. Non-ASM Rust parity: 13 matches, 24 diagnostic
  differences, zero failures.

## Full-suite performance

Frozen binaries use `-o:speed -microarch:native -debug`, CPU 2 affinity, seed 1,
terminal 200x50, input 190x46, unpaced `/dev/null` output, three samples and
minimum 0.3-second batches. Child CPU/RSS come from wait4. The harness `rust`
label means the before Odin binary. Matrix/Thunderstorm use separate one-second
wall-clock diagnostics and are excluded from the 35-effect aggregate. Builds
and validation finished before measurement; the two comparisons ran sequentially.
ASM was not rerun.

Against requested-state particles with four separate boolean columns:

```
throughput summary (35 effects, unweighted means):
  best wall 48.9ms / 49.2ms, mean CPU 48.9ms / 49.2ms, peak RSS 12.7 MiB / 12.8 MiB
  geometric wall-speedup 0.99x, Odin/Rust CPU 1.01x, Odin/Rust RSS 1.01x
```

[All 35 flag comparisons](particle-flags-benchmark.tsv).

Against the earlier fast immediate-value particle queue:

```
throughput summary (35 effects, unweighted means):
  best wall 49.3ms / 49.0ms, mean CPU 49.4ms / 49.1ms, peak RSS 12.7 MiB / 12.8 MiB
  geometric wall-speedup 1.00x, Odin/Rust CPU 0.99x, Odin/Rust RSS 1.00x
```

[All 35 original-baseline comparisons](particle-flags-reference-benchmark.tsv).
All 35 finite-effect frame counts match. Matrix/Thunderstorm remain wall-clock
diagnostics, including the original-baseline Thunderstorm count of 5039/5174;
the virtual-clock correctness captures are byte-identical. Initial best-wall
slowdowns over 2% are listed below.

| Comparison | Effect | Before ms | Flags ms | Change |
|---|---|---:|---:|---:|
| Booleans | blackhole | 74.8 | 76.6 | +2.4% |
| Booleans | bubbles | 74.9 | 77.8 | +3.9% |
| Booleans | burn | 43.9 | 46.2 | +5.2% |
| Booleans | fireworks | 117.7 | 120.6 | +2.5% |
| Booleans | middleout | 28.3 | 31.3 | +10.6% |
| Booleans | waves | 36.0 | 37.8 | +5.0% |
| Original | None | | | |

The six initial regressions against separate booleans were screened again with
five samples and one-second minimum batches, after both full suites finished:

| Effect | Booleans ms | Flags ms | Change |
|---|---:|---:|---:|
| blackhole | 74.8 | 76.3 | +2.0% |
| bubbles | 74.7 | 74.6 | -0.1% |
| burn | 43.9 | 46.0 | +4.8% |
| fireworks | 117.6 | 120.6 | +2.6% |
| middleout | 28.2 | 31.2 | +10.6% |
| waves | 35.5 | 37.0 | +4.2% |

Engine flags/layout change: +35/-26 lines (net +9).
Requested-state simplification plus flags vs deferred gather: +124/-201 (net -77).

Artifacts: `/tmp/otfx-particle-flags-20260926/`, including frozen binaries,
source/test/docs snapshots, captures, benchmark logs, size diagnostics, scripts,
and scoped diffs. `before` is the corrected-layout boolean requested-state
version; `reference` is the earlier immediate-value queue; `after` has packed
flags. The preceding requested-state suite was interrupted by the flag/layout
request; its preserved partial refresh is not used as a completed result here.
Earlier completed experiments remain preserved. No commits were made.

SHA-256:

- before: `b9c4d54360ffe729f7eb5c0cb7ad110810d050b137a5fd66969d5c7ea079993b`
- reference: `2ba4581156e254ac4c558bac380d904de1a1db205d76a1b152ae78c86f2a6ef3`
- after: `1e8480aebb05c0a75ae04960b60f1c31fe2ae6bb97dba6f38e8262b22e7812df`
