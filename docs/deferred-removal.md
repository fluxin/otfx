# Ordered insertion with deferred removal compaction

Update: control B (top pops plus deferred interior compaction) was subsequently
accepted and brought into the working tree. See [shared motion](shared-motion.md)
for validation and the combined measurements. The experiment below remains the
isolated comparison; nothing has been committed.

2026-09-26. Two isolated controls against checkpoint `3850833c`, following
the [per-cell arrival merge experiment](cell-batch-merge.md). Production source
is unchanged. Sources, binaries, and reviewable patches are preserved; nothing
was committed or deleted.

## Algorithm

Keep the existing sorted insertion path. A departure sets the particle's
published cell to absent and queues its previous cell once. Its old key stays
in sorted order while other arrivals are inserted. At the end of composition,
compact each queued cell, keeping keys whose particle still belongs to that
cell and whose layer matches. Select its final winner and dirty it if needed.

Same-cell layer changes temporarily retain old and new keys; the layer check
removes the old key. The update queue is deduplicated, so a particle has only
one final placement processed per frame. No arrival buffer, merge pass, or
arrival sort is needed. Added state is one compaction flag per cell and one
reusable list of cell indices reserved from canvas size.

Control A defers every removal. Control B keeps the existing immediate `pop`
when the departing particle is the stack's top, deferring only interior
departures. Top removal shifts nothing, so deferring it adds avoidable work.
If a cell already has deferred interior departures, it still compacts after
any subsequent top pops or arrivals. Both controls preserve sorted membership.

## Four-effect screen

Three samples, minimum 0.5 seconds per sample. Native `-o:speed
-microarch:native -debug`, assertions enabled. CPU 2, terminal 200x50,
190x46 input/default canvas, seed 1, frame-rate zero, stdout `/dev/null`.
Full CLI construction/playback/cleanup; CPU and peak RSS from `wait4`.
No builds, tests, or captures ran during timings. No fresh ASM timing.

| Effect | Before A | All removals deferred | Before B | Interior only deferred |
| --- | ---: | ---: | ---: | ---: |
| Middleout | 25.9 ms | 15.9 ms | 25.9 ms | 15.9 ms |
| Expand | 24.5 ms | 25.3 ms | 24.4 ms | 24.5 ms |
| Slide | 20.8 ms | 26.9 ms | 20.8 ms | 20.7 ms |
| Binarypath | 159.1 ms | 195.6 ms | 159.2 ms | 168.5 ms |

Control A is not a general improvement; its four-effect mean regresses 14.5%.
Restoring top pops removes most of that regression. The screening frame counts
match for both controls. [Control A CPU/RSS data](deferred-remove-screen.tsv).

## Full 35-effect suite for control B

Two samples, minimum 0.5 seconds each, otherwise identical protocol.

| Metric | Before | Interior only deferred |
| --- | ---: | ---: |
| Mean best wall | 33.151 ms | 33.191 ms |
| Mean child CPU | 33.029 ms | 33.074 ms |
| Mean per-effect peak RSS | 12,946 KiB | 13,175 KiB |

Arithmetic wall is effectively unchanged (**0.12% higher**); CPU is 0.14%
higher, RSS 1.77% higher. Geometric wall-speedup is 1.014x. No aggregate
throughput win is established. All 35 frame counts match.

Middleout improves **25.9 → 16.0 ms**. Binarypath regresses **159.2 → 168.3 ms**,
offsetting most of that saving. Other measured regressions above 2% are Crumble
45.4→46.4, Swarm 104.8→107.2, Unstable 41.6→43.1, and Wipe 4.4→4.5 ms;
Scattered is approximately 2% slower, 44.9→45.8 ms. Small changes, especially
0.1 ms, are screening observations rather than established changes beyond
noise. [All 35 wall/CPU/RSS/frame results](deferred-interior.tsv).

The remaining tradeoff is that insertion operates on arrays containing departed
keys until compaction. It can search and shift entries that will later be
removed; this cost was not isolated with counters in these controls. Deferred
compaction also scans retained occupants once. The results support the narrower
split over universal batching, but do not justify replacing production yet.

## Validation

- Both controls pass `odin check` and optimized build; changed files formatted.
- Control A: 222/222 per-frame canvas captures match; 197 exact byte streams.
  Differences are redundant row emissions in Bubbles, Expand, Orbittingvolley,
  Scattered, and Spray; prefix, cleanup, and frame counts match.
- Control B: **222/222 exact byte-stream captures match**, including clipped,
  no-color, xterm, and existing-color modes.
- Both: 81/85 tests pass; the same four allocation-test names fail:
  appearance_packet_survives_placement_changes,
  bounded_playback_reuses_build_storage,
  frame_composition_character_growth_is_amortized,
  rebuilt_output_storage_does_not_grow. Counts differ; no claim of identical
  allocation behavior or allocation-free playback.
- Finite-effect timing excludes Matrix/Thunderstorm; those effects are covered
  by virtual-clock captures. No additional standalone parity/smoke acceptance
  run was performed for these unpromoted experiments.

Artifacts: `/tmp/otfx-deferred-remove-20260926/` and
`/tmp/otfx-deferred-interior-20260926/`. The latter includes `change.patch`,
`candidate/src`, binaries, `screen.log`, `bench.log`, `tests.log`,
`capture-final.json`, `results.tsv`, and `summary.json`.
