# Prefix bytes owned by Appearance

Historical measurement of the first deferred-prefix version. The later
[appearance-flag experiment](appearance-flag.md) removes the prefix length field
and moves all appearance invalidation discovery into rendering.

`Appearance` holds colors, bold, a fixed 43-byte ANSI prefix, its length, and a
stale-prefix bit. `shared_appearances` remains `[dynamic]Appearance` with explicit
caller-controlled ID sharing. Glyphs stay on particles; complete packets stay in
cell slots. Neither the appearance map nor glyph map remains.

Creation and style setters only invalidate the prefix. During the dirty-cell
loop, the renderer selects the winning particle's appearance, encodes a stale
prefix once, then copies it, writes that particle's UTF-8 glyph and reset, and
clears slot padding. Multiple style writes before rendering coalesce; hidden
and covered styles do not encode. Glyph edits leave the prefix valid. `.Always`
selects the initial appearance.

Appearance-value assignment compares logical colors/bold, ignores supplied
prefix bytes, and invalidates on change. Preview rendering uses a local copy,
so it cannot prematurely clear the retained appearance's stale bit. No complete
packet is stored per particle, and temp allocator reset placement is unchanged.

## Validation

- Source, docs/accuracy tools, and instrumented phase checks pass.
- All 37 effects pass the four-frame smoke matrix; `git diff --check` passes.
- 222/222 exact captures against the split-map binary, which also matched the
  frozen direct encoder exactly; 37 effects × six fixtures, seed 42 and virtual
  clock. Matrix/Thunderstorm use 1-second virtual windows.
- Normal and instrumented tests: 55/59 pass. The same four pre-existing
  allocation-test names fail; no gate was relaxed. The prefix test checks
  shared/private isolation, deferred edits, hidden particles, glyph-only changes,
  empty/four-byte glyphs, no-color/xterm modes, stale caller copies, and previews.
- Rust non-ASM parity: 13 matches, 24 diagnostic differences, zero failures.

## Paired performance

Both CLI binaries use `-o:speed -microarch:native -debug`, CPU 2, seed 1,
190×46 input, 200×50 terminal, unpaced output to `/dev/null`, three samples with
minimum 0.3 s batch duration. The harness's `rust`/`odin` labels mean frozen
direct-encoding Odin / deferred-prefix Odin. Matrix and Thunderstorm are excluded
from fixed-duration throughput. ASM was not rerun.

```
throughput summary (35 effects, unweighted means):
  best wall 50.9ms / 49.1ms, mean CPU 51.0ms / 49.3ms, peak RSS 10.2 MiB / 12.4 MiB
  geometric wall-speedup 1.02x, Odin/Rust CPU 0.97x, Odin/Rust RSS 1.22x
```

[Full per-effect wall, CPU, RSS, and frame data](appearance-bytes-benchmark.tsv).
All 35 frame counts match. Prefix storage raises RSS; appearance values also
occur in private particle storage, input cells, and effect timelines. This is
not a blanket performance win: the initial effects over 2% slower are listed
below, including changes small enough to need further noise checks.

| Effect | Direct ms | Prefix ms | Change |
|---|---:|---:|---:|
| beams | 30.7 | 31.9 | +3.9% |
| burn | 40.3 | 43.7 | +8.4% |
| highlight | 5.4 | 5.8 | +7.4% |
| overflow | 29.0 | 29.7 | +2.4% |
| randomsequence | 5.2 | 5.7 | +9.6% |
| spotlights | 49.1 | 50.3 | +2.4% |
| sweep | 11.4 | 12.2 | +7.0% |
| synthgrid | 13.7 | 14.3 | +4.4% |
| vhstape | 36.2 | 40.2 | +11.0% |
| wipe | 6.9 | 7.6 | +10.1% |

The earlier eager-prefix variant encoded in setters. Its full run was
51.0 → 49.2 ms mean best wall, 51.1 → 49.2 ms CPU, and 10.2 → 12.4 MiB mean
per-effect peak RSS. It is preserved as `eager`, `eager-src`, and `eager-tests`
with its [per-effect data](appearance-bytes-eager-benchmark.tsv); the working
version implements the requested deferred encoding. The earlier
[map experiments](render-cache.md) remain preserved too.

Artifacts: `/tmp/otfx-appearance-bytes-20260926/` contains binaries, source/test
snapshots, capture/test/parity logs, benchmark data, commands, and the scoped
diff. `before` is the split-map correctness baseline; `direct` is the benchmark
baseline; `after` is the deferred-prefix binary. Nothing was committed.

The engine change against the split-map snapshot is +50/-64 lines (net -14).
The measured binary is also installed as `./otfx`; final source differs from
its build only in two comments clarifying that encoding occurs during rendering.

SHA-256:

- before: `d1aca07880d80f62b130bb0d2a71fb21a01fb55bd0f958ddb1d2d495fc667b1c`
- direct: `58c513057623a7daf51bed339925657787b5a281808741fdc7fa20b1a3fc5f31`
- eager: `1038be27e0d1d1e5341f44882609596466c104fe8de89abffc9a6fc6e2291bb9`
- after: `85de29ff7f080c9ce5768ae3a9635460f4526f5fe2544e64f6bad37de0965420`
