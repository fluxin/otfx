# Fixed row-slot experiment

Decision: reject the row-slot renderer for the current engine. It works, but
is about 19% slower by geometric mean in an eight-effect screen and adds
placement/appearance/fallback bookkeeping. The smaller packet renderer remains
the reference at `b0cb53df`. The experiment is preserved in JJ history and local
artifacts under `/tmp/otfx-row-slots-20260925`.

## Design tested

Each row owns one persistent byte slice. A cell reserves 43 bytes of SGR,
four bytes for a glyph, and four bytes for the reset: 51 bytes total. No-color
mode uses four bytes per cell. Unused bytes are NUL, which libvterm ignores
without moving its cursor. A change from a four-byte glyph to ASCII clears the
unused glyph bytes and leaves neighboring cells at their original offsets.

The visual table stores only logical appearances; `Visual_Entry` and its packet
cache are removed. Appearance setters patch the winning cell's row bytes
directly. Placement changes still resolve overlaps and re-encode the affected
rows. Row flags distinguish placement, appearance, and long-symbol fallback.
Ordinary output borrows one slice per dirty row, plus cursor movement slices.
Symbols longer than four bytes remain supported by borrowing their complete
string between slices of the row; they are not truncated.

This reduces descriptors and memory, but it removes the prepared byte cache.
Switching a palette entry or rebuilding a moving row now performs appearance
encoding that the previous renderer avoided. It also sends padding for blank
and unstyled cells. Reducing one output cost does not reduce all frame work.

## Performance

Both binaries use `-o:speed -microarch:native -debug`; baseline `b0cb53df`.
Dense 190x46 input, 200x50 canvas, seed 1, unpaced `/dev/null` output, CPU 2,
three samples with a 0.3-second minimum. All frame counts match. The harness's
`rust` label denotes the old Odin renderer here, not ttfx ASM.

| Effect | Previous packets, ms | Fixed row slots, ms |
| --- | ---: | ---: |
| Colorshift | 24.0 | 35.4 |
| Decrypt | 103.4 | 97.0 |
| Waves | 34.0 | 36.6 |
| Rings | 226.4 | 255.2 |
| Middleout | 29.5 | 29.0 |
| Binarypath | 347.0 | 398.9 |
| Burn | 164.6 | 232.1 |
| Laseretch | 392.1 | 600.9 |

Geometric speedup: 0.84x. Mean best wall time: 165.1 -> 210.6 ms; mean CPU:
166.2 -> 210.5 ms; average peak RSS: 11.4 -> 9.5 MiB. This is a rejection
screen, not a claim about all effects or physical terminal throughput.
[Raw paired measurements](row-slots-benchmark.tsv).

The initial prototype, before giving the compiler exact constant-size stores,
was slower still: 0.79x geometric speedup, mean best wall 165.0 -> 226.0 ms.
The exact-size version is the final experimental code.

## SIMD finding

The color writer previously used `copy(bytes, template)` with an unknown-length
slice. In the native build that generated a length calculation and a `memcpy`
call. Writing `copy(bytes[:19], template)` makes its existing 19-byte contract
explicit. Disassembly shows `vmovups` loading/storing 16 bytes plus the remaining
three bytes; no `memcpy` call remains in `packet_color`.

This is SIMD within a packet, not vectorization across multiple cells. Fields
in separate row slots have a 51-byte stride. A multi-cell SIMD encoder would
still need interleaving or scatter to put the results into output order. The
small fixed-size-store change can be measured independently in the old renderer
without retaining the row-slot design.

## Correctness and limits

- 46 tests pass, including direct pre-frame row mutation, 1/2/3/4-byte glyph
  transitions, clearing unused bytes, stable neighboring slots, long symbols,
  placement/occlusion, color-policy transitions, and bounded playback storage.
- 222/222 terminal-model comparisons match the reference.
- 222/222 comparisons through installed libvterm 0.3.3 match every displayed
  cell after each frame and the final cursor. Fixtures cover all 37 effects,
  color policies, no color, Unicode/xterm colors, and clipping/wrapping.
- The libvterm harness applies LF -> CRLF, corresponding to normal TTY ONLCR
  output processing. Feeding unprocessed redirected stdout into the emulator
  initially gave false mismatches; this harness correction is not an engine fix.
- Docs, accuracy, and parity tools pass `odin check`.

NUL compatibility was tested in libvterm, not every terminal emulator. The
four-byte reservation concerns UTF-8 storage, not grapheme display width. The
existing engine's display-width behavior is unchanged. Long-symbol fallback can
grow the output descriptor array; normal one-rune playback does not allocate.

Padding also increases output volume. Across the 37-effect small-fixture
captures (40x12 canvas), plain input output grows from 15,127,459 to 61,117,655
bytes (4.04x); no-color output grows 2.60x; xterm/Unicode grows 3.31x. These are
byte counts, not emulator timing measurements, and use smaller inputs than the
CPU benchmark. `/dev/null` timings do not account for parsing those extra bytes.
