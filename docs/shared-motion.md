# Shared motion inputs and retained compaction

Subsequent retained effect change: [Fireworks held publication](fireworks-holds.md)
reduces Fireworks from 65.9 to 56.9 ms with unchanged output.

Follow-up: [alternating-order revalidation and fresh profiles](shared-motion-revalidation.md)
confirm both effect gains and identify their remaining costs. The 35-effect
aggregate below remains provisional; it was not rerun during that follow-up.

2026-09-26. Working-tree changes, not committed. Deferred interior compaction is retained at the user's direction; Binarypath's regression is accepted while work focuses on effects still behind ASM. Ordered insertion and immediate top pops remain.

Scattered now evaluates progress/easing once per distinct duration per frame. Fireworks computes launch position once per shell; individual burst and return paths remain unchanged. The generic build helper `engine.group_values` returns unique inputs plus an index per original lane. Its map is destroyed after construction; playback uses arrays. Neither change stores a complete animation or adds a renderer cache.

## Shared API

```odin
// All fields that affect the shared calculation belong in this key.
Key :: struct {
    start, stop: int,
    easing: ease.Ease,
}
keys, slots := engine.group_values(inputs[:])
// Allocate one result per key during build.
// Each frame: calculate results once for keys, then use results[slots[i]].
```

Scattered's start and easing are common to the whole effect, so its key is simply duration. Storage is bounded by the number of particles, not animation duration; very slow configured motion does not allocate an enormous duration-indexed table. Fireworks already has shell membership, so it reuses those indices directly.

This is explicit grouping of calculation inputs, not implicit deduplication of particle appearances or setter requests. It complements the existing sequence/action primitives; it does not automatically change `sequence_batch` or combine unrelated effect timelines. Effects retain ownership of phase timing, active membership and final publication.

Odin's `core:math/ease` Flux API was inspected in the installed compiler. It keeps a map of tweens keyed by destination pointer and evaluates easing separately per active tween. It could animate a shared group scalar, but does not itself deduplicate equal timing inputs. No Flux dependency or second scheduler was added.

## Isolated measurements

Frozen compaction-only baseline versus effect changes, real full CLI including construction/playback/cleanup, CPU 2, terminal 200x50, input/default canvas 190x46, seed 1, frame-rate 0, stdout `/dev/null`. Native `-o:speed -microarch:native -debug`, scoped bounds annotations, assertions enabled. Two or three samples, minimum 0.5 seconds per sample; no concurrent builds/tests/profiling during timing. Child CPU and RSS use wait4.

| Screen | Before ms | After ms | Frames | Mean CPU before/after ms | Peak RSS before/after KiB |
|---|---:|---:|---:|---:|---:|
| Scattered, initial local grouping | 45.8 | 31.1 | 420 / 420 | 45.7 / 31.0 | 10020 / 9880 |
| Fireworks, shared shell launch | 72.6 | 65.9 | 1516 / 1516 | 72.5 / 65.7 | 16268 / 16252 |
| Scattered, final shared helper | 45.7 | 30.9 | 420 / 420 | 45.6 / 30.8 | 9892 / 10100 |
| Fireworks, final shared-helper binary | 72.4 | 65.6 | 1516 / 1516 | 72.2 / 65.4 | 16232 / 16232 |

The build diagnostic has 7,084 input particles. Scattered has 375 distinct durations: total easing evaluations drop from 1,069,746 to 71,447. Fireworks has 21 shells: total launch-position evaluations drop from 1,419,254 to 4,026. These counts exclude the remaining per-particle interpolation, color and renderer work.

## Full suite, provisional timing

Compared frozen pre-compaction production (`3850833c` source) against the combined compaction plus two effect changes. All 35 finite-effect frame counts match. [All wall/CPU/RSS rows](shared-motion-benchmark.tsv), [recorded ASM context and frame counts](shared-motion-asm-context.tsv).

| Unweighted metric | Before | Combined |
|---|---:|---:|
| Mean best wall | 33.231 ms | 32.791 ms |
| Mean child CPU | 33.203 ms | 33.197 ms |
| Mean per-effect peak RSS | 12,949 KiB | 13,132 KiB |

Arithmetic wall is 1.32% lower; geometric wall speedup is 1.026x. The small aggregate gain is not treated as settled because timing variability appeared late in this run. Recorded ASM mean is 30.763 ms at revision `c2be6411d3e4d5002f160dc0cbd10af7cb3a3889`; the combined result is numerically 6.6% higher. ASM was not fetched, rebuilt or retimed, and differing frame/RNG behavior remains visible in the table.

The initial full run reports >2% regressions in Binarypath (159.6→169.5), Rings (87.8→89.8), Slice (10.5→10.8), Spotlights (37.2→41.2) and Unstable (42.0→43.3). Binarypath is the accepted compaction tradeoff and remains below the recorded ASM 183.4 ms. The others are reported rather than silently omitted.

Follow-up controls retained, not substituted into the aggregate:

- Swarm full-run best was 105.8→107.8 ms, but candidate mean wall was 124.4 ms. A three-sample repeat shifted both binaries to 126.0→121.8 ms best (mean CPU 126.9→125.2). Comparing compaction-only to combined then gave 132.8→127.1 ms best. This is evidence of timing instability, not an established new Swarm speedup.
- Spotlights compaction-only versus combined gave 36.9→42.6 ms best (mean CPU 37.1→45.6). A subsequent pre-compaction production versus combined repeat gave 37.1→36.7 ms best (mean CPU 40.1→36.6). A persistent 10% regression is not established, but these noisy runs do not isolate its cause.
- No benchmark results were discarded, and no environmental cause was assumed. The independently repeated Scattered/Fireworks reductions are stronger evidence than the small aggregate difference.

## Validation and artifacts

- `odin check src` passed; changed files formatted with odinfmt.
- `odin test tests`: 82/86 pass, with the same four allocation-test failures as the earlier baseline. The new complete-key/order/empty-input grouping test passes. Failed tests: `appearance_packet_survives_placement_changes`, `bounded_playback_reuses_build_storage`, `frame_composition_character_growth_is_amortized`, `rebuilt_output_storage_does_not_grow`. No assertions were weakened.
- 222/222 standard captures byte-identical to frozen production, including the compaction change.
- 84/84 additional Scattered/Fireworks captures byte-identical across seeds, color modes, movement speeds/easing, shell volume, launch delay and explode-anywhere.
- Dense benchmark-fixture outputs byte-identical for both changed effects: Scattered 148,453,446 bytes, Fireworks 414,439,991 bytes.
- 37/37 smoke checks. Parity tool: 13 frame-count matches, 24 diagnostic differences, zero failures. This tool checks completion/final content; it does not establish per-frame visual equality with ASM. Matrix/Thunderstorm are included as virtual-clock correctness cases, not in finite-effect throughput.

Artifacts: `/tmp/otfx-outlier-work-20260926/`, containing frozen `compaction`, `scattered`, `fireworks`, `shared`, benchmark logs, capture scripts/results, diagnostic source/counts, test/parity logs. Final `shared` SHA256: `8178705a5c8aad771c736ba67dff212ec2e7aa19c0f2cef10b2ac3710ba2a38c`. `before` points to `/tmp/otfx-held-bulk-20260926/after`; `after` points to `shared`. The root `otfx` executable was not replaced.

The remaining audit priorities are held appearance publication in Slide/Expand/Fireworks, Spotlight color/distance work, Blackhole phase worklists, and renderer glyph-only patching. They are not implemented by this change; see [outlier audit](outlier-audit-20260926.md).
