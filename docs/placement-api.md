# Placement setters and rune visuals

The placement API now separates single-field edits from complete placement:

```odin
engine.set_particle(e, id, position)
engine.set_particle(e, id, engine.Visible(true))
engine.set_particle(e, id, engine.Layer(2))
engine.set_particle(e, id, coord = position, visible = true, layer = 2)
engine.set_visual(e, id, prepared_visual)
engine.set_visual(e, id, engine.Visual{symbol = '░', colors = {fg = color}})
```

`set_position`, `set_visible`, and `set_layer` have explicit implementations.
They check and mutate only their own field, then maintain affected membership.
They do not delegate to `set_placement`. The combined overload requires all three
values, checks `placement_changed` once, assigns the complete tuple, and removes
and inserts membership at most once. There are no optional placement fields or
appearance union. Existing equality guards remain.

`Visual.symbol`, effect symbol collections, and symbol setters use `rune`.
UTF-8 encoding happens when updating the cached packet. Rune zero means empty;
invalid Unicode scalar values assert. CLI symbol flags reject malformed UTF-8
and multiple-code-point arguments. This does not add grapheme shaping or
terminal display-width handling. Input setup no longer allocates a string for
each glyph; Colorshift's symbol lookup uses rune keys.

`Visual.colors` is an explicit `Color_Pair`, without `using`. Its foreground and
background remain optional to distinguish terminal-default colors from explicit
RGB black. On the measured native target:

| Storage | Before | After |
|---|---:|---:|
| `Visual` | 32 B | 16 B |
| `Visual_Entry`, including cached packet | 88 B | 72 B |
| `Color_Pair` | 8 B | 8 B |

## Measurement

Frozen baseline: the layer-bucket renderer immediately before this API change.
Both programs are Odin; the harness's `rust` label means the frozen baseline,
not ttfx. No ASM binary was rebuilt or rerun.

Build flags: `-o:speed -microarch:native -debug`. CPU affinity: `taskset -c 2`.
The full 35-effect run uses seed 1, a 190×46 input, 200×50 terminal, unpaced output
to `/dev/null`, three samples with a 0.3 s minimum batch duration. CPU is child
user+system from `wait4`. Per-effect RSS is the maximum observed child RSS.

| Unweighted 35-effect aggregate | Before | After |
|---|---:|---:|
| Mean of best wall times | 49.7 ms | 48.4 ms |
| Mean child CPU | 49.7 ms | 48.5 ms |
| Mean of per-effect peak RSS | 15.5 MiB | 14.1 MiB |

Geometric wall speedup: 1.03×. All 35 frame counts match.
[Full per-effect results](placement-api-benchmark.tsv) include every effect,
including slowdowns. Pour (23.7→24.2 ms) and Wipe (7.4→7.6 ms) exceeded 2% in
this screen. A reverse-order check (five samples, minimum 1 s batches, CPU 2)
preserved both slowdown directions:

| Effect | Before | After |
|---|---:|---:|
| Pour | 23.7 ms | 24.2 ms |
| Wipe | 7.5 ms | 7.6 ms |

Pour remains about 2% slower; Wipe's repeated difference is about 1–2% at the
reported precision. The aggregate improves, but this is not an every-effect win.
The reversed harness labels mean `rust=after`, `odin=before`.

## Validation and retained artifacts

- `odin check src`, tools/docs, tools/accuracy, tools/parity, and instrumented
  bench/phases pass.
- 222/222 exact captures match (37 effects × six fixtures: plain, no-color,
  SGR-always, SGR-dynamic, xterm, clipped).
- Normal and instrumented test suites: 51/55 pass. The same four allocation
  gates already failed in the frozen baseline: `appearance_packet_survives_placement_changes`,
  `bounded_playback_reuses_build_storage`, `frame_composition_character_growth_is_amortized`,
  and `rebuilt_output_storage_does_not_grow`. Assertions were not weakened.
- The full-paint oracle exercises both complete placement and independent typed
  setters, including clipping, negative/equal layers, hiding, and particle growth.
- Symbol tests cover 1–4-byte UTF-8, empty glyphs, surrogate/out-of-range runes,
  default versus explicit colors, and invalid CLI symbol input.
- Parity: 13 frame-count matches, 24 existing diagnostic differences, zero
  failures against the non-ASM Rust reference.

Artifacts: `/tmp/otfx-placement-api-20260926/` contains frozen sources/tests/docs,
`before`, `after`, build/test/capture logs, all benchmark logs, and
`placement-api.patch` (source/test/existing-document changes from the frozen
baseline). Tool capture consumers also changed to read runes and `colors`.
The intermediate optional-placement version is preserved as
`optional-placement`, `optional-placement-src`, and `optional-placement-tests`;
its exploratory benchmark is `benchmark-optional-placement.log`.

Binary SHA-256:

- Before: `f1a9dc9c4c09ade9f58bcabd5d6009eeff85c4fb38103293c77d4ab1ba473034`
- After: `8aa79164b447fd8c53070f048c41a4a38c702aecf250f9c63b8b1e3d726d13a0`

No changes were committed. The existing cell-bucket allocation experiment remains
active; this API change does not resolve those allocation gates.
