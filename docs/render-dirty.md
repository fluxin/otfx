# Appearance dirtying and fixed prefix

Preserved intermediate experiment, superseded by the
[appearance-flag implementation](appearance-flag.md).

`dirty_appearance` marks only the current winning cell. It no longer marks a row.
The dirty-cell render loop marks the row after patching the cell bytes. Covered,
hidden, and clipped appearance edits therefore do not enqueue unchanged rows.
`is_visible` remains effect-controlled eligibility; `cell.top` is the displayed
particle. Existing ownership changes still publish the newly exposed cell.

`Appearance.length` is removed. Styled output uses the full 43-byte prefix;
plain/no-color output omits it based on existing appearance and config fields.
The 51-byte colored cell slot (four bytes in no-color mode) remains fixed width.
Prefix encoding stays deferred until a dirty cell needs it.

No particle flags, mutation queues, full-grid scan, or new ownership paths were
added. Diagnostic row counting now runs after rendering has selected emitted
rows, so the phase instrumentation includes appearance-only changes correctly.

## Validation

- `odin check src`, docs/accuracy tools, instrumented phase check, formatting,
  and `git diff --check` pass.
- 60 normal and instrumented tests: 56 pass, the same four pre-existing
  allocation failures remain. Added a covered-particle test checking no emitted
  row until the cover is removed, then the updated glyph and style appear.
- All 37 effects pass the four-frame smoke matrix.
- 222 capture cases preserve frame-by-frame terminal cells, glyphs, colors,
  bold, and frame counts. 167 remain byte-identical; 55 differ only in redundant
  row emission and pass terminal replay. Seed 42, virtual clock, six fixtures;
  Matrix/Thunderstorm use one-second virtual windows.
- Rust non-ASM parity: 13 matches, 24 diagnostic differences, zero failures.

## Performance

Frozen before/after Odin binaries: `-o:speed -microarch:native -debug`, affinity
CPU 2, seed 1, terminal 200×50, input 190×46, unpaced `/dev/null` output, three
samples with 0.3-second minimum batches. CPU/RSS use `wait4`. The benchmark's
`rust` label denotes the before Odin binary. ASM was not rerun. Matrix and
Thunderstorm are excluded from finite-effect throughput.

```
throughput summary (35 effects, unweighted means):
  best wall 49.1ms / 49.7ms, mean CPU 49.2ms / 49.8ms, peak RSS 12.4 MiB / 12.4 MiB
  geometric wall-speedup 0.99x, Odin/Rust CPU 1.01x, Odin/Rust RSS 0.99x
```

[All 35 effects, wall/CPU/RSS and frame counts](render-dirty-benchmark.tsv).
All frame counts match. Initial per-effect slowdowns over 2% are listed below;
these have not received a separate noise check.

| Effect | Before ms | After ms | Change |
|---|---:|---:|---:|
| binarypath | 245.0 | 251.6 | +2.7% |
| bouncyballs | 46.6 | 48.9 | +4.9% |
| expand | 36.2 | 37.2 | +2.8% |
| orbittingvolley | 33.2 | 34.0 | +2.4% |
| pour | 23.7 | 24.7 | +4.2% |
| print | 14.3 | 14.6 | +2.1% |
| slide | 30.6 | 31.7 | +3.6% |

Artifacts and the scoped patch are in `/tmp/otfx-render-dirty-20260926/`.
The previous version is preserved as `before` and `before-src`/`before-tests`;
`dirty-only` preserves the intermediate binary before removing the length field.
No commits were made.

SHA-256:

- before: `85de29ff7f080c9ce5768ae3a9635460f4526f5fe2544e64f6bad37de0965420`
- after: `7c96d5aea6b979e7a6d31f5a144d639d2a3f3ec6ca9b68900fdde600215c2ab5`
