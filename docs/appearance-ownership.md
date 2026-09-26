# Appearance ownership and cell packets

The working API separates glyphs from shared styling:

```odin
appearance_id := engine.prepare_appearance(e, engine.Appearance{colors = {fg = red}})
a := engine.add_particle(e, 'A', appearance_id, position_a)
b := engine.add_particle(e, 'B', appearance_id, position_b)
engine.set_symbol(e, a, 'C') // keeps appearance sharing
```

`shared_appearances` is `[dynamic]Appearance`. Each appearance contains only
`Color_Pair` and bold. Creation always appends; no map, interning, deduplication,
entry wrapper, or encoded prefix cache remains. Constructors require a supplied
ID and never create appearances. `init_particle` and `set_symbol` live in
`particle.odin`. Input and generated-particle builders use this same contract.

Particles own current/initial glyphs, initial/shared appearance IDs, and a local
appearance value for individual styling edits. An individual glyph edit does
not detach the shared appearance. A local style edit does; other particles and
the initial reference remain unchanged.

Complete packets exist only in the fixed cell-byte grid. Setters publish data
and mark dirty cells; the renderer encodes the winner directly into each marked
slot. Hidden and covered particles have no packet. The per-particle `Visual_Entry`,
`Packet`, packet-field flags, private packet updates, and shared encoded packet
pool are removed. The preview helper uses the same encoder with a local array.
Temp allocator reset placement is unchanged.

Colorshift now has one gradient appearance palette instead of the
symbol-by-gradient product and symbol lookup map. Decrypt's ciphertext palette
is independent of its glyph alphabet. Waves and frame timelines retain separate
glyph/appearance columns. RNG draws, effect timing, layers, and placement rules
are unchanged.

## Validation

- `odin check src`, docs/accuracy tools, and instrumented phase checks pass.
- Normal and instrumented tests: 54/58 pass. The same four pre-existing allocation
  test names fail; no allocation assertion was relaxed. Constructor, explicit
  sharing across distinct glyphs, local edits, initial references, input style,
  overlap, clipping, and UTF-8 tests remain covered.
- 222 deterministic captures: 216 byte-identical. Six changed streams replay
  to identical cell glyphs/colors/bold at every logical frame, with equal frame
  counts. Differences are redundant row emissions: Waves in four fixtures and
  Colorshift/Decrypt under `.Always`. No duplicate-ID map or special dirtying
  was restored to manufacture byte equality.
- Rust non-ASM parity: 13 frame-count matches, 24 diagnostic differences, zero
  failures. The ASM oracle was not rerun.

## Paired performance

Baseline is the frozen indexed-layer, ordered-removal renderer before the
explicit-appearance migration. Both CLI binaries use
`-o:speed -microarch:native -debug`; CPU 2; input 190×46, terminal 200×50;
seed 1; unpaced `/dev/null`; three samples, minimum 0.3 s each.
The harness labels `rust` and `odin` mean before/after **Odin** here.
Matrix and Thunderstorm are excluded from this fixed-duration aggregate and
included in virtual-clock correctness captures.

| Metric | Before | Cell-owned packets |
|---|---:|---:|
| 35-effect mean best wall | 47.5 ms | 50.9 ms |
| Mean child CPU | 47.5 ms | 51.3 ms |
| Mean per-effect peak RSS | 12.1 MiB | 10.2 MiB |

Geometric speedup: 0.95x. All 35 frame counts match. This is approximately a
7% aggregate wall regression and 15% lower mean RSS, **not a performance-neutral
cleanup**. Re-encoding styling during cell updates replaces previously cached
packet copies. The implementation stays available for review as requested;
neither this experiment nor the previous implementation was discarded.

[Full per-effect data](appearance-ownership-benchmark.tsv) includes wall, CPU,
RSS, and frame counts. Effects over 2% slower in the initial run are listed
below; small differences have not all received independent noise checks.

| Effect | Before ms | After ms | Change |
|---|---:|---:|---:|
| binarypath | 232.6 | 275.2 | +18.3% |
| blackhole | 77.7 | 79.3 | +2.1% |
| bouncyballs | 44.6 | 47.6 | +6.7% |
| bubbles | 73.4 | 78.6 | +7.1% |
| burn | 38.1 | 40.1 | +5.2% |
| colorshift | 24.5 | 39.6 | +61.6% |
| crumble | 58.4 | 62.5 | +7.0% |
| decrypt | 27.1 | 36.8 | +35.8% |
| errorcorrect | 16.4 | 18.3 | +11.6% |
| laseretch | 55.5 | 56.9 | +2.5% |
| orbittingvolley | 32.4 | 35.2 | +8.6% |
| pour | 23.7 | 25.6 | +8.0% |
| print | 13.8 | 15.1 | +9.4% |
| rain | 22.6 | 23.7 | +4.9% |
| rings | 106.4 | 116.9 | +9.9% |
| scattered | 60.0 | 64.4 | +7.3% |
| slice | 13.6 | 14.4 | +5.9% |
| slide | 30.1 | 32.3 | +7.3% |
| smoke | 16.0 | 16.7 | +4.4% |
| spray | 58.2 | 59.8 | +2.7% |
| swarm | 148.0 | 154.6 | +4.5% |
| unstable | 72.4 | 76.9 | +6.2% |
| waves | 22.2 | 40.6 | +82.9% |

Artifacts are in `/tmp/otfx-appearance-20260926/`: before/after binaries, source
snapshots, capture and cell-replay scripts/results, test/parity logs, benchmark
logs, and a scoped diff. The superseded explicit-visual intermediate is also
preserved under `/tmp/otfx-explicit-visuals-20260926/`. No commit was made.

Binary SHA-256:

- Before: `93428c382774243cdb585b7d51931751e4cc8dd1d39f8c76e3d8f8cb7589e40b`
- After: `d911013e8d69efc68628d3f23f8e2f12168345255f50ff22f105162bd7ae2f84`

Reverse-order confirmation (five samples, minimum 1 s, same flags/affinity):

| Effect | Before ms | After ms |
|---|---:|---:|
| binarypath | 233.0 | 275.1 |
| colorshift | 24.7 | 39.6 |
| decrypt | 27.1 | 36.8 |
| waves | 22.2 | 40.5 |
