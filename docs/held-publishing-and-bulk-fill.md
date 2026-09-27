# Held publication and bulk timeline filling

2026-09-26. Two separately measured changes, then a combined full-suite check.
Baseline includes plain u32 IDs, descriptor initialization removal, and inline
dirty-bit traversal. No renderer semantics or setter guards changed.

## Held samples

- Wipe publishes at sample boundaries, including age zero after re-entry;
  active-list retirement still occurs on the last held tick.
- Highlight publishes its two-tick samples on even ages. Dynamic input colors
  and the missing-foreground lifetime are preserved.
- Decrypt publishes fast glyphs every two ticks and installs the cipher
  appearance once on phase entry. Slow glyphs publish on entry or sample
  transition. Discovered colors publish every five ticks, retaining completion.
- Scattered retains its last gradient step in one byte per non-dynamic particle
  and calculates/publishes color only when the step changes. Build installs step
  zero. Movement, the initial hold, exact final color/coordinate, and layer reset
  remain unchanged. No color-step storage is allocated in dynamic mode.

Three samples per affected effect against the frozen baseline:

| Effect | Before | Held-publication change |
| --- | ---: | ---: |
| Wipe | 5.1 ms | 4.6 ms |
| Highlight | 3.6 ms | 3.4 ms |
| Decrypt | 28.6 ms | 24.6 ms |
| Scattered | 47.9 ms | 44.8 ms |

[Isolated wall, CPU, RSS, and frame results](held-publishing.tsv).

## Bulk construction

The shared hold/gradient constructors extend the Frame_Timeline once and fill
its SoA columns directly. `non_zero_resize` avoids preliminary clearing because
every field of each new frame is assigned. Duration/count assertions remain.
The existing constructor API and SoA representation are unchanged.

Sweep used direct frame appends rather than these constructors. Its build now
sizes the complete timeline once and fills each particle's two borrowed spans.
The random draw order, symbols, colors, per-frame durations, and span boundaries
are unchanged. The single-frame append API remains available.

Isolated three-sample screen against the same baseline: Wipe 5.1 → 4.9 ms,
Sweep 5.9 → 5.7 ms. [Full isolated measurements](bulk-timeline-fill.tsv).

## Combined full composition

Native builds use `-o:speed -microarch:native -debug`; assertions enabled.
CPU 2, terminal 200x50, input 190x46, seed 1, frame rate zero, stdout
`/dev/null`. Each sample batches at least 0.5 seconds of complete CLI runs.
The combined 35-effect suite uses two samples; isolated screens use three.
All builds and validation finished before timing. ASM was not rerun.

| Metric | Before | Combined |
| --- | ---: | ---: |
| 35-effect mean best wall | 33.354 ms | 33.086 ms |
| Mean child CPU | 33.257 ms | 32.977 ms |
| Mean peak RSS | 12,927 KiB | 12,948 KiB |

Mean best wall drops 0.81%; CPU drops 0.84%; geometric speedup 1.012x.
All frame counts match. No effect regresses beyond 2%; unchanged effects show
small timing variation. [Full combined results](held-publishing-and-bulk-fill.tsv).
The recorded ASM c2be6411 mean remains 30.763 ms: current Odin is 7.55% slower,
requiring about 7.02% less time to match that reference. This is whole-animation
timing, with differing frame counts for some effects, not equal-work rendering.

## Validation and output distinction

- Formatting, normal/stats-enabled checks, and native build pass.
- 85 tests: 81 pass; same four existing allocation failures:
  `appearance_packet_survives_placement_changes`,
  `bounded_playback_reuses_build_storage`,
  `frame_composition_character_growth_is_amortized`,
  `rebuilt_output_storage_does_not_grow`.
- New regression verifies timeline span offsets, preservation of existing
  frames, and complete initialization when reusing nonzero SoA storage.
- Standard matrix: 221/222 byte-identical streams. The remaining Decrypt
  preserve-input-color case has identical canvas packet bytes on all 462 frames,
  but output drops from 1,529,648 to 638,244 bytes by omitting redundant redraws.
  Its unused shared cipher appearance stays dirty because rendering uses the
  initial appearance; repeated prepared-appearance setter calls used to dirty
  rows even though visible styling stayed unchanged.
- Additional held/re-entry/options matrix: combined 264/264 frame-by-frame
  matches (260 exact streams); held-only 252/252 (248 exact streams). The four
  differences are the same Decrypt redundant-redraw case. The replay checks
  every retained row packet per frame, frame count, prefix, and cleanup trailer.
- Bulk-only matrix: 192/192 exact streams, including overshooting Wipe easing,
  hold lengths 1/3/7, delay 0/2, input color modes, and multibyte Sweep glyphs.
- Existing 354 edge captures remain exact. Smoke 37/37; parity 13 matches,
  24 existing diagnostic differences, zero failures.

Sources, binaries, scripts, and logs are preserved under
`/tmp/otfx-held-publishing-20260926/`, `/tmp/otfx-bulk-timeline-20260926/`, and
`/tmp/otfx-held-bulk-20260926/`. Root `./otfx` remains unchanged.
