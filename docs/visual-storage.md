# Shared and particle-owned visuals

A particle now owns its private visual and references shared appearances explicitly:

```odin
Particle :: struct {
    // Other particle fields omitted.
    initial_visual_id: Visual_Id,
    shared_visual_id:  Visual_Id, // zero selects private_visual
    private_visual:    Visual_Entry,
}

// Engine storage:
shared_visuals: [dynamic]Visual_Entry
```

`Visual_Id` always indexes the shared pool. `initial_visual_id` always refers to
an immutable shared entry containing the original glyph and style. Identical
initial appearances can share that entry. Changing the active appearance does
not change this initial reference.

`set_visual(e, id, shared_id)` selects a shared entry. The first field setter
that changes it copies the shared value into the particle, edits it, and clears
`shared_visual_id`. Further edits directly update the private entry. Selecting
a shared ID again replaces the private appearance; stale private fields are
not merged back in. A complete `Visual` assignment writes the supplied value
directly into the particle without first copying the shared value. Equal
assignments remain no-ops.

The private entry includes the cached packet. Because particles use
`#soa[dynamic]Particle`, these private entries already form a contiguous column.
There is no separate private-visual table and no `mutable_visual_id`. The active
entry resolver selects either the shared pool entry or the particle's own entry;
rendering does not combine two appearances.

The existing Always input-color policy still encodes a private packet when
necessary, using colors from `initial_visual_id`. This preserves per-particle
input colors without modifying a shared entry. Ordinary construction still
initializes the private glyph; effects may subsequently attach a prepared shared
visual. This change does not alter those initialization semantics.

## Validation

- `odin check src`, tools/docs, tools/accuracy, and instrumented bench/phases pass.
- 222/222 byte-identical captures match the frozen baseline (37 effects × six
  fixtures covering plain, no-color, SGR-always, SGR-dynamic, xterm, and clipping).
- Normal and instrumented suites: 52/56 tests pass. The same four pre-existing
  allocation tests fail; their assertions are unchanged.
- A new regression checks two particles sharing a visual, independent local
  edits, unchanged shared values and packets, and reselecting shared before a
  subsequent edit. It also checks rendered output for both particles.
- Parity against non-ASM Rust: 13 frame-count matches, 24 diagnostic differences,
  zero failures.

## Measurement protocol

The frozen baseline is the preceding placement/rune API implementation, including
explicit single-field setters and required combined placement arguments. Both
programs are Odin. Harness labels `rust` and `odin` mean before and after here.
No ASM binary was rebuilt or rerun.

Both CLI builds use `-o:speed -microarch:native -debug`. The benchmark uses CPU 2,
seed 1, a 190×46 input, 200×50 terminal, unpaced output to `/dev/null`, three
samples with a minimum 0.3 s batch duration. CPU is child user+system from
`wait4`; per-effect RSS is the maximum observed child RSS.

| Unweighted 35-effect aggregate | Before | After |
|---|---:|---:|
| Mean of best wall times | 48.4 ms | 47.6 ms |
| Mean child CPU | 48.5 ms | 47.6 ms |
| Mean of per-effect peak RSS | 14.1 MiB | 14.8 MiB |

Geometric wall speedup: 1.02×. All frame counts match. No effect is more than
2% slower in this screen; smaller differences remain in the
[full per-effect results](visual-storage-benchmark.tsv). The ownership change
improves the aggregate slightly but increases measured RSS. Removing an ID does
not guarantee a lower RSS: the private entries now share particle capacity and
growth, while the shared pool has separate capacity. This run does not isolate
each capacity decision's contribution.

Binary SHA-256:

- Before: `8aa79164b447fd8c53070f048c41a4a38c702aecf250f9c63b8b1e3d726d13a0`
- After: `b6db98398461c6271db7abc3a351466c89f3dabe634af60d1745f45cd8111c89`

Artifacts are retained in `/tmp/otfx-visual-storage-20260926/`: frozen sources,
tests and docs, before/after binaries, capture and test logs, benchmark logs,
and a scoped patch. The intermediate separate-private-table source is retained
in `separate-private-src` and `separate-private-tests` for review. It was replaced
by particle-owned storage at the user's request, without benchmarking that
intermediate version. No changes are committed.
