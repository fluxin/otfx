# Plain 32-bit cell owners

2026-09-26. At user request, retain `Particle_Id :: distinct u32` and replace
`Maybe(Particle_Id)` cell owners with plain `Particle_Id`.

`NO_PARTICLE :: max(Particle_Id)` marks an empty cell. Valid IDs run from zero
through `NO_PARTICLE - 1`. Population checks reserve the sentinel before
allocation/narrowing, and `init_particle` rejects it explicitly. Particle zero
remains valid. A particle displaying a space remains an occupied cell.

This removes optional-tag extraction/comparison from cell removal, patching,
stats, and tool consumers. `Render_Cell` stays 64 bytes because its surrounding
fields require alignment; owner storage itself drops from eight to four bytes.
The initial cell grid is explicitly filled with the sentinel. No other renderer
or effect optimization is included.

## Validation

- Optimized native/debug build and stats-enabled check pass. Accuracy/docs
  tool checks and parity build pass.
- 84 tests: 80 pass, the same four existing allocation-test failures:
  `appearance_packet_survives_placement_changes`,
  `bounded_playback_reuses_build_storage`,
  `frame_composition_character_growth_is_amortized`, and
  `rebuilt_output_storage_does_not_grow`.
- 222 standard and 354 edge captures: 576 exact matches against the frozen
  `u32`/Maybe binary. Smoke 37/37. Parity 13 matches, 24 existing diagnostic
  differences, zero failures.
- Tests distinguish ID zero from an empty cell and reject both sentinel
  construction and a batch large enough to consume the reserved ID.

## Paired performance

Frozen u32/Maybe and u32/sentinel builds, `-o:speed -microarch:native -debug`,
CPU 2, terminal 200x50, input 190x46, seed 1, frame rate zero, output
`/dev/null`. Two samples with at least 0.5 seconds of child runs per sample.
All compilation and validation completed before timing. No ASM rerun.

| Metric | Maybe owner | Plain owner |
| --- | ---: | ---: |
| 35-effect mean best wall | 34.717 ms | 34.637 ms |
| Mean child CPU | 34.717 ms | 34.551 ms |
| Mean peak RSS | 13,049 KiB | 13,009 KiB |

Timing is essentially flat (0.23% lower mean best wall); geometric speedup
1.003x. All frame counts match, and no effect exceeds 2% regression against
the Maybe version. [Full per-effect results](u32-cell-owners.tsv).

A separate three-sample comparison against the original machine-sized-ID,
scoped-check build isolates the previously flagged effects:

| Effect | Original scoped build | Plain u32 owner |
| --- | ---: | ---: |
| Overflow | 11.7 ms | 11.7 ms |
| Print | 8.1 ms | 8.2 ms |
| Smoke | 14.0 ms | 14.6 ms |

Overflow's regression is gone and Print's is smaller. Smoke remains 4.3%
slower than that older build; removing the optional tag did not resolve it.
This control is targeted, not a fresh full-suite comparison against the
original machine-sized-ID version.

Sources, binaries, scripts, and logs are preserved in
`/tmp/otfx-u32-sentinel-20260926/`. The prior Maybe version remains preserved
in `/tmp/otfx-u32-particles-20260926/`. Nothing committed; root `./otfx` unchanged.
