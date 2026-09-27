# Inline dirty-bit iteration

2026-09-26. Isolated follow-up to the output descriptor initialization change.
Changed `src/engine/render.odin`, `output.odin`, and `stats.odin`; no effect
updates, bitmap writes, public APIs, or storage layouts changed.

## Implementation and controls

The first control added `#force_inline` at calls to
`bit_array.iterate_by_set`. Assembly still called its private
`iterate_internal_` implementation at all four render/output call sites.
The full 35-effect paired mean best wall was 35.214 → 35.631 ms (1.18%
slower). This version is preserved separately and is not the working version.

The retained version adds a private `next_dirty_bit` inline procedure using
`bit_array.Bit_Array_Iterator`. It scans words, finds the next set bit, and
advances the existing iterator state. Ascending order, bias, and logical-length
checks are preserved. Dirty cells, emitted rows, captures, and optional stats
use this same traversal. No extra persistent state or allocation is introduced.

Assembly has no iterator calls in `main::run_effect_once` after this change;
the unrelated effect-side native iterator calls remain. No new bounds-check
suppression or global compiler flags are used.

## Validation

- Formatting and `odin check src` pass, including `-define:OTFX_FRAME_STATS=true`.
- Optimized native/debug CLI builds successfully.
- 84 tests: 80 pass, with the same four pre-existing allocation failures:
  `appearance_packet_survives_placement_changes`,
  `bounded_playback_reuses_build_storage`,
  `frame_composition_character_growth_is_amortized`, and
  `rebuilt_output_storage_does_not_grow`.
- Both controls pass 222 standard + 354 edge + 10 tall-frame exact captures
  against the frozen baseline. The tall cases cross the output descriptor
  chunk boundary. Smoke 37/37; parity 13 matches, 24 existing diagnostic
  differences, zero failures.
- A separate test against Odin's native iterator passes 252 combinations:
  14 lengths from 0 through 10,000, three biases, and six empty/dense/sparse/
  boundary patterns. Test source and log are in the experiment directory.

## Paired full-composition results

Both builds use `-o:speed -microarch:native -debug`, assertions enabled.
The baseline includes the accepted output descriptor change and plain u32 IDs.
Full CLI construction, playback, and cleanup; CPU 2; terminal 200x50;
input 190x46; seed 1; frame rate zero; stdout `/dev/null`. Two samples per
effect with at least 0.5 seconds per sample. No builds, tests, or profiles
overlapped timing. ASM was not rerun.

| Metric | Before | Inline traversal |
| --- | ---: | ---: |
| 35-effect mean best wall | 34.400 ms | 33.429 ms |
| Mean child CPU | 34.303 ms | 33.363 ms |
| Mean peak RSS | 12,995 KiB | 13,005 KiB |

Mean best wall is 2.82% lower; CPU is 2.74% lower; geometric speedup 1.036x.
Every frame count matches. No effect exceeds a 2% regression; Spotlights
is the sole best-wall increase (37.5 → 37.7 ms, 0.53%).

| Effect | Before | After |
| --- | ---: | ---: |
| Colorshift | 22.0 ms | 20.0 ms |
| Print | 7.7 ms | 7.1 ms |
| Laseretch | 47.2 ms | 44.8 ms |
| Binarypath | 167.2 ms | 163.0 ms |
| Swarm | 106.7 ms | 104.4 ms |
| Middleout | 26.1 ms | 26.1 ms |

[All 35 per-effect timings, CPU, RSS, and frame counts](inline-dirty-iteration.tsv).
This is a shared improvement, not a resolution of the crowded-stack or
effect-update costs identified in the audit.

Frozen before/after sources, binaries, commands, logs, and assembly:
`/tmp/otfx-inline-traversal-20260926/`. The wrapper-only control remains in
`/tmp/otfx-inline-dirty-20260926/`. Nothing committed; root `./otfx` unchanged.
