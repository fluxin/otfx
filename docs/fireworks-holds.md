# Fireworks phase and held-color publication

2026-09-26, uncommitted working tree. Shared-motion and deferred-compaction changes are retained. This additional change only touches `src/effects/fireworks.odin`.

Fireworks now publishes the launch glyph, visibility and layer at launch, restores the input glyph when the burst starts, and submits colors only when their sample changes. A `u8` per particle remembers the last burst/fall sample; phase entry forces the first sample. Completed return motion stops submitting position while its color finishes. The two outgoing motion branches share the color-sampling block. Existing engine setters and their guards remain unchanged; no new scheduling or renderer API was added.

## Measurements

Frozen before: `/tmp/otfx-outlier-work-20260926/shared`, the retained shared-motion version. Frozen after: `/tmp/otfx-fireworks-holds-20260926/after`. Native speed/native architecture/debug build, assertions enabled; CPU 2, seed 1, terminal 200x50, dense input/default canvas 190x46, frame-rate 0, stdout `/dev/null`. Full CLI build/playback/cleanup included.

| Metric | Before | After |
|---|---:|---:|
| Native best wall, three samples | 65.9 ms | 56.9 ms |
| Native mean wall | 65.9 ms | 57.0 ms |
| Native mean child CPU | 65.6 ms | 56.8 ms |
| Native peak RSS | 16232 KiB | 16232 KiB |
| Frames | 1516 | 1516 |
| Alternating-order median batch wall | 65.783 ms | 56.949 ms |
| Alternating-order median batch CPU | 65.450 ms | 56.641 ms |

Native samples are at least 0.5 seconds each. Six alternating before/after pairs, eight complete CLIs per batch, confirm a 13.43% wall reduction; all six pairs improve. Candidate batch means range 56.871–57.021 ms. Native wait4 measurements supply RSS; the Python alternating harness's inherited launcher RSS floor is not used as effect memory. Raw logs and all alternating measurements are under `/tmp/otfx-fireworks-holds-20260926/`.

Recorded ASM Fireworks is 62.5 ms at `c2be6411d3e4d5002f160dc0cbd10af7cb3a3889`; the new native result is 5.6 ms (9.0%) lower. ASM was not rebuilt or retimed. Its recorded 1553 frames differ from Odin's 1516, so this compares complete animations, not equal frame counts.

[Per-effect ASM context](fireworks-holds-asm-context.tsv) retains the last full-suite rows and replaces only Fireworks with this fresh measurement. Its arithmetic mean is an **updated snapshot estimate**, 32.546 ms versus recorded ASM 30.763 ms (5.8% higher); 10/35 effects are faster. The 35-effect suite was not rerun. The prior noisy Spotlights (41.2 ms; later repeat 36.7 ms) and Swarm rows remain explicitly provisional. Do not present this table as a new simultaneous suite measurement.

## Validation already completed

- odinfmt and `odin check src` passed.
- 222/222 standard captures exact; 48/48 Fireworks option captures exact; 120/120 edge captures exact (three color modes, two seeds, single-character/multiline/Unicode/styled input, zero/full shell volumes and explosion distances, white firework color, alternate glyphs, xterm and no-color).
- Dense output remains byte-identical: 414,439,991 bytes, SHA256 `b67cf8c75f96c18d98e145d038fc7315d0ae1758402a0de30de134646a0a666d`.
- Tests remain 82/86 with the same four known allocation failures; no new failure. Existing Fireworks retirement/final-color contract passes.
- 37/37 smoke checks. Fireworks parity diagnostic completes with zero failures; its differing frame count is diagnostic, not a visual equality claim.

These checks were completed before the user's request to stop repeating tests and show the ASM chart. No additional test suite or full benchmark was run afterward. Nothing was committed; the root executable was not replaced. Remaining work is tracked in the [profile report](shared-motion-revalidation.md).
