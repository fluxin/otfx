# Unified particle publication

Creation now uses the same update queue as subsequent changes. `init_particle`
queues an entry with `previous_cell = -1` and sets `Update_Queued`. Later setters
overwrite requested values and deduplicate into that entry. The existing renderer
passes remove old memberships and publish final placements, including new ones.
`composed_particles`, its setter guard, and the separate new-particle scan are gone.
Build can still initialize fresh particle columns directly before their first frame.
Input/fill construction reserves queue capacity before populating those particles.

`cell_owner` is removed; engine instrumentation, tests, preview, accuracy, and
parity consumers read `.top` directly. Blank-cell encoding copies the read-only
`Blank_Cell` template, one space followed by zeros, into either the four-byte or
51-byte slot. The space erases and advances; NUL padding alone cannot erase.
Canvas/row/cell borrowing and temporary-allocator lifetime remain unchanged.

## Validation

- Source formatting/check, native optimized debug build, docs/accuracy checks,
  and stats-enabled phase check pass.
- Normal and stats-enabled tests: 60/64 pass. The same four pre-existing allocation
  failures remain: `appearance_packet_survives_placement_changes`,
  `bounded_playback_reuses_build_storage`, `frame_composition_character_growth_is_amortized`,
  and `rebuilt_output_storage_does_not_grow`. Their assertions were not weakened.
- Added a witness for initialization admission, deduplicated pre-render edits,
  creation after playback starts, and a new particle hidden before first publication.
- All 222 captures are byte-identical to the saved cell-view baseline: six fixtures,
  37 effects, seed 42, virtual clock, one-second Matrix/Thunderstorm windows.
- All 37 effects pass four-frame smoke. Non-ASM Rust parity reports 13 matches,
  24 diagnostic differences, zero failures.

## Full-suite measurements

Before is the completed cell-byte-view experiment; after includes unified
publication, direct `.top` reads, and the blank template. Both frozen binaries use
`-o:speed -microarch:native -debug`. The benchmark uses CPU 2, seed 1, terminal
200x50, dense input 190x46, unpaced output to `/dev/null`, three samples and minimum
0.3-second batches. CPU/RSS are from wait4. Harness `rust` means before Odin.
No build/test/profile work ran concurrently. Matrix/Thunderstorm use separate
one-second wall-clock diagnostics and are excluded from throughput. ASM was not rerun.

```
throughput summary (35 effects, unweighted means):
  best wall 49.0ms / 48.0ms, mean CPU 49.4ms / 48.1ms, peak RSS 12.9 MiB / 13.2 MiB
  geometric wall-speedup 1.02x, Odin/Rust CPU 0.97x, Odin/Rust RSS 1.03x
```

[Full per-effect table](unified-publication-benchmark.tsv). All 35 finite-effect
frame counts match. Initial best-wall regressions over 2% are listed below; these
short samples alone do not establish whether small differences exceed noise.

| Effect | Before ms | After ms | Change |
|---|---:|---:|---:|
| None | | | |

Engine source delta: +13/-21 lines (net -8).

Commands:

```sh
odin check src
odin build src -o:speed -microarch:native -debug -out:/tmp/otfx-unified-publication-20260926/after
odin test tests
odin test tests -define:OTFX_FRAME_STATS=true
UV_CACHE_DIR=/tmp/uv-cache uv run python /tmp/otfx-unified-publication-20260926/capture.py
BENCH_MIN_SECONDS=0.3 BENCH_MATRIX_RAIN_TIME=1 BENCH_STORM_TIME=1 taskset -c 2 /tmp/otfx-unified-publication-20260926/bench 3
```

Frozen binaries, source snapshots, scoped diff, test logs, capture results,
and benchmark output are under `/tmp/otfx-unified-publication-20260926/`.
No commits were made and earlier experiments remain preserved.

SHA-256:

- before: `67ce6d0524e75bd5557d7d9a4a27b8690884d4db406a43d5389324a3b2c54809`
- after: `2687dcb86d1a426d3765b37771754b87d70e27567dbcb30208f3e4d0b04b5b2e`
