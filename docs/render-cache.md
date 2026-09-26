# Renderer map experiments (preserved)

Two renderer-owned caches were tried after glyph/appearance separation.
Neither changed the caller's explicit appearance-ID sharing contract.

- Combined: `{symbol: rune, appearance_id: Appearance_Id}` is an 8-byte key;
  values are fixed 51-byte packets. Immutable shared appearances use the map;
  mutable private styles bypass it. `.Always` uses the initial appearance ID.
- Split: `map[Appearance]Encoded_Appearance` stores prefixes, and
  `map[rune]Encoded_Glyph` stores UTF-8 bytes. Appearance-value keys safely include
  private styles and reuse equal style bytes across separately created IDs.
  There is no per-entry byte-slice allocation.

Each compared real native debug binaries against the same frozen direct cell
encoder, pinned to CPU 2. Input 190×46, terminal 200×50, seed 1, unpaced stdout
`/dev/null`; three samples with at least 0.3 s per sample. Labels rust/odin mean
before/after Odin. These are fixed-duration 35-effect aggregates; ASM was not rerun.

| Paired experiment | Before / after mean best wall | Before / after mean child CPU | Before / after mean peak RSS |
|---|---:|---:|---:|
| Combined cache | 51.0 / 51.3 ms | 51.0 / 51.4 ms | 10.1 / 10.4 MiB |
| Split caches | 50.9 / 58.2 ms | 50.9 / 58.5 ms | 10.1 / 10.5 MiB |

The combined map was roughly flat; split maps regressed wall time about 14%.
Avoiding encoding did not offset lookup/copy/assembly work in this implementation.
This is a measurement of these paths, not a claim that all caches are slower.
Full per-effect wall/CPU/RSS/frame data: [combined](render-cache-combined-benchmark.tsv)
and [split](render-cache-split-benchmark.tsv). All 35 frame counts match in both.

Both preserve 222/222 exact captures. Combined tests: 54/58 pass; split normal and
instrumented tests: 55/59 pass. The same four pre-existing allocation-test names
fail; map growth adds allocations. Split parity: 13 matches, 24 diagnostic frame
count differences, zero failures. A cache test covers private style changes,
shared styles across distinct glyphs, Unicode, empty glyphs, no-color and xterm.

The user subsequently authorized replacing these maps with prefixes held directly
in `Appearance`. Both variants remain in `/tmp/otfx-render-cache-20260926/`, with
binaries, `combined-src`, `split-src`, split tests, capture/test/benchmark logs,
input, and the scoped split-cache diff. No commits were made.
