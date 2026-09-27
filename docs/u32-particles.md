# 32-bit particle IDs and optional cell owners

Historical experiment, superseded by [plain cell owners](u32-cell-owners.md).
The `u32` ID type remains; the optional cell owner was removed at user request.

2026-09-26. In this experiment, `Particle_Id` is `distinct u32`; `Render_Cell.top` is
`Maybe(Particle_Id)`. `nil` means no winning particle. Particle zero and the
maximum ID remain ordinary IDs; a space glyph does not mean an empty cell.

The renderer already constrained packed particle IDs to 32 bits. The type now
expresses that contract. Input/fill construction, batch reservation, and single
addition check the population before narrowing or allocating. Layers, canvas
coordinates, and published cell indices are unchanged. In particular, the
signed offscreen cell index is distinct from particle identity.

Measured sizes on the installed 64-bit Odin compiler:

| Type | Before | After |
| --- | ---: | ---: |
| `Particle_Id` | 8 B | 4 B |
| `Maybe(Particle_Id)` | 16 B | 8 B |
| `Render_Cell` | 64 B | 64 B |

ID arrays use half the element storage. Other structures can retain padding;
this does not imply all particle-related storage halves. Zero initialization
now creates empty cell owners, removing the separate `top = -1` loop.

`u16` is insufficient for supported dense Binarypath inputs: 190x46 non-space
glyphs produce 69,920 additional bit particles, before the original canvas
population. The normal benchmark text contains spaces, but is not a capacity
limit for the API.

Production changes: `src/engine/particle.odin`, `input.odin`, `render.odin`,
`engine.odin`, and `stats.odin`. Raster witnesses and the accuracy, docs, and
parity tools now unwrap optional owners. The former oversized-ID constructor
test checks oversized batch admission instead, because an out-of-range typed
ID is no longer representable. A regression test distinguishes ID zero from
absence and checks that the maximum ID remains representable.

## Validation

- `odin check src` and stats-enabled checking pass; optimized native/debug
  build passes. Accuracy/docs tools and phase benchmark checking pass.
- 83 tests: 79 pass, the same four existing allocation failures:
  `appearance_packet_survives_placement_changes`,
  `bounded_playback_reuses_build_storage`,
  `frame_composition_character_growth_is_amortized`, and
  `rebuilt_output_storage_does_not_grow`.
- 222 standard plus 354 edge captures: 576 exact matches against the frozen
  scoped-check build. Smoke 37/37. Parity 13 matches, 24 existing diagnostic
  differences, zero failures.
- One additional dense 190x46 Binarypath capture matches exactly, exercising
  more than 65,536 particles in a supported complete animation.

## Paired performance screen

Frozen before/after binaries with `-o:speed -microarch:native -debug`, CPU 2,
terminal 200x50, input 190x46, seed 1, frame rate zero, output `/dev/null`.
Two samples, at least 0.5 seconds of child runs per sample. No builds or
validation ran during this full-suite measurement. Harness `rust` means the
previous scoped Odin build, not ASM.

| Metric | Before | After | Change |
| --- | ---: | ---: | ---: |
| 35-effect mean best wall | 34.480 ms | 34.663 ms | 0.53% slower |
| Mean child CPU | 34.351 ms | 34.531 ms | 0.52% higher |
| Mean peak RSS | 13,225 KiB | 12,953 KiB | 2.06% lower |

All frame counts match. [Per-effect results](u32-particles.tsv) retain the
best/mean wall, CPU, RSS, and frame counts. The screen is a small aggregate
slowdown, not a performance improvement. Overflow, Print, and Smoke exceed
2% slowdown. A separate three-sample recheck confirms the regressions:

| Effect | Before | After | Slowdown |
| --- | ---: | ---: | ---: |
| Overflow | 11.7 ms | 12.3 ms | 5.1% |
| Print | 8.1 ms | 8.3 ms | 2.5% |
| Smoke | 14.1 ms | 14.6 ms | 3.5% |

The change is retained uncommitted for review as a storage/type cleanup, with
these regressions disclosed. The combined experiment does not attribute the
cost separately to narrower ID arrays versus optional-owner code generation.
The accepted recheck ran after all validation finished. An earlier recheck
overlapped the dense capture and is preserved as
`recheck-overlapped-discarded.log`; it is excluded from reported results.

Artifacts: `/tmp/otfx-u32-particles-20260926/` preserves before/after source,
binaries, layout probe, validation logs, and benchmark commands. Nothing
committed; root `./otfx` was not replaced. No other audit optimization is
included in this change.
