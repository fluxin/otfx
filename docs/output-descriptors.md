# Output descriptor initialization

2026-09-26. The only production change in this experiment is
`storage: [1024]linux.IO_Vec = ---` in `print_frame`.

Storage was already preallocated on the stack. Every descriptor passed to
`write_vectors` is explicitly assigned, including after each full-buffer
flush; unused entries are excluded by `storage[:count]`. Zero initialization
therefore serves no purpose. Disassembly confirms removal of the 16,368-byte
`memset` emitted for the old declaration. Cursor storage and partial-write
retry logic are unchanged.

## Validation

- Formatting, `odin check src`, and native optimized/debug build pass.
- 84 tests: 80 pass, the same four existing allocation failures:
  `appearance_packet_survives_placement_changes`,
  `bounded_playback_reuses_build_storage`,
  `frame_composition_character_growth_is_amortized`, and
  `rebuilt_output_storage_does_not_grow`.
- 222 standard and 354 edge captures are byte-identical to the frozen before
  binary. Ten additional colored/no-color Print captures at heights 511,
  512, 513, 1024, and 1100 match across the descriptor chunk boundary.
- Smoke 37/37; parity 13 matches, 24 existing diagnostic differences, zero
  failures. Partial kernel writes were not deliberately forced.

## Paired performance

Both binaries use `-o:speed -microarch:native -debug`. Full CLI lifecycles,
CPU 2, terminal 200x50, input 190x46, seed 1, frame rate zero, stdout
`/dev/null`. Two samples per effect, at least 0.5 seconds per sample.
No builds, tests, or profiling overlapped timing. No ASM rerun.

| Metric | Before | After |
| --- | ---: | ---: |
| 35-effect mean best wall | 34.674 ms | 34.363 ms |
| Mean child CPU | 34.580 ms | 34.260 ms |
| Mean peak RSS | 12,906 KiB | 12,950 KiB |

Mean best wall is 0.90% lower; geometric speedup is 1.011x. This is a small
measured improvement, not a large engine gain. Frame counts all match;
no effect regresses more than 2%. [Full per-effect results](output-descriptors.tsv).

Canvas padding is a separate issue: zero-initialized storage can contain old
packet bytes after reuse. Odin's UTF-8 encoder already zero-pads its four-byte
result, so a full glyph copy clears its own unused bytes. Styled packet
transitions can still leave stale bytes beyond the new reset sequence.
No canvas clearing changes are mixed into this experiment.

Frozen sources, binaries, scripts, disassembly, and logs are under
`/tmp/otfx-output-init-20260926/`. Nothing committed; root `./otfx` unchanged.
