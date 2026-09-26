# Borrowed cell byte views

`canvas_bytes` owns the allocation. Rows borrow whole-row slices and cells now
borrow individual fixed-width slots from that same allocation. Construction sets
each `Render_Cell.bytes` once. `patch_cell(e, &cell)` reads the winning ID and
writes directly through `cell.bytes`; it no longer computes `index * cell_stride`
and slices the canvas on each patch. Dirty-row tracking retains the cell index.

No packet is duplicated and no per-cell allocation is added. Row output still
writes its existing contiguous view; setters still change requested values only,
leaving completed canvas bytes untouched until rendering. The canvas allocation
is fixed for the engine's lifetime, so the borrowed views remain valid.

This exchanges address calculation for stored slice metadata. On this build,
`[]byte` is 16 bytes and `Render_Cell` grows from 48 to 64 bytes: 160,000 extra
metadata bytes for a 10,000-cell canvas. Particle packing, appearance ownership,
dirty tracking, packet encoding, and temporary-allocation lifetime are unchanged.

The byte layout is still a 51-byte slot (four with no color). Styled content uses
a cached 43-byte appearance prefix, a UTF-8 glyph of up to four bytes, then a
four-byte reset. Unused tail bytes are NUL-filled. Plain content omits the style
prefix/reset; a blank cell contains a space followed by NULs. Only dirty cells
are patched, and each row slice sees those writes without rebuilding a row.

## Validation

- Formatting, source check, optimized native debug build, docs/accuracy checks,
  and instrumented phase check pass.
- Normal and stats-enabled tests: 59/63 pass, with the same four existing
  allocation test failures. No test assertions changed for this experiment.
- All 222 captures are byte-identical to the packed-flag baseline. Six fixtures,
  seed 42, virtual clock; one-second Matrix/Thunderstorm windows.
- All 37 effects pass smoke. Non-ASM Rust parity reports 13 matches,
  24 diagnostic differences, zero failures.

## Full-suite comparison

Both frozen binaries use `-o:speed -microarch:native -debug`, CPU 2 affinity,
seed 1, terminal 200x50, input 190x46, unpaced `/dev/null` output, three samples,
minimum 0.3-second batches, and wait4 CPU/RSS. The harness `rust` label means the
before Odin binary. Matrix/Thunderstorm have separate one-second wall-clock
diagnostics, excluded from the 35-effect aggregate. Validation/builds finished
before measurement. ASM was not rerun.

```
throughput summary (35 effects, unweighted means):
  best wall 49.1ms / 49.0ms, mean CPU 49.3ms / 49.0ms, peak RSS 12.7 MiB / 12.9 MiB
  geometric wall-speedup 1.00x, Odin/Rust CPU 0.99x, Odin/Rust RSS 1.01x
```

[All 35 effects](cell-byte-views-benchmark.tsv). All finite-effect frame counts
match. Initial best-wall slowdowns over 2% follow; small differences have no
independent noise screen.

| Effect | Before ms | Cell view ms | Change |
|---|---:|---:|---:|
| None | | | |

Engine source delta: +9/-5 lines (net +4).

## Baseline hotspot diagnostic

Before adding cell views, the packed-flag binary was sampled over 30 full
Laseretch runs with user-cycle perf sampling (1999 Hz, DWARF call graphs, CPU 2,
same dense input). About 3,000 samples were collected with none lost. This
includes initialization and excludes kernel cycles; it is not the 35-effect
aggregate profile.

The flat effect-update symbol accounted for 22.60% (including inlined setters),
dirty-bit iteration 7.24%, and cell insertion 5.65%. Much rendering was inlined
into the runner: packet-copy call chains showed 6.36%, appearance lookup 3.99%,
and patch-cell-local instructions 2.23%. Those inline call-chain figures are
diagnostic attribution, not additive independent phase totals. The profile does
not establish address calculation as the dominant renderer cost.

An instrumented seven-effect phase run separately measured about 62.9 patched
cells/frame for Laseretch and 3526.7 for Colorshift. It includes instrumentation
overhead and should not be compared directly with shipping-binary wall times.
Raw phase TSV, perf data, and report are preserved under
`/tmp/otfx-particle-flags-20260926/`.

This experiment's before/after binaries, source/test/docs snapshots, captures,
size diagnostic, benchmarks, scripts, and scoped diff are preserved under
`/tmp/otfx-cell-byte-views-20260926/`. No commits were made.

SHA-256:

- before: `1e8480aebb05c0a75ae04960b60f1c31fe2ae6bb97dba6f38e8262b22e7812df`
- after: `67ce6d0524e75bd5557d7d9a4a27b8690884d4db406a43d5389324a3b2c54809`
