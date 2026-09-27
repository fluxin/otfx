# Timed action batches — 2026-09-26

The incoming work is checkpointed as `60a4495e` (change `sxouqmus`). This
experiment is uncommitted. It implements the requested keypoint/action API
and uses Swarm as its first consumer. It has not achieved the 50% reduction
target or beaten the cached latest ASM Swarm result.

**Review outcome:** this draft does not meet the user's combined simplicity and
performance goal. It adds 180 production lines for a 0.53% aggregate best-wall
improvement (0.17% CPU). No rollback has been performed without approval, and
the root `otfx` binary remains the checkpoint version. The experiment source,
tests and patch are preserved for review before deciding what to remove.

## Data contract

`Sequence_Keypoint` owns a `[start, stop)` frame interval and borrows a slice
of typed `Sequence_Action` values. `sequence_batch` evaluates the overlap
between those intervals and a requested output window into borrowed SoA
frame storage. Actions are dispatched once per overlapping keypoint/action;
their inner loops walk contiguous samples. Keypoints apply in slice order,
so later actions can overwrite earlier columns. Unwritten columns retain
their supplied contents; callers must initialize or cover the fields they
intend to load.

The initial actions are easing, line movement, foreground palette selection,
color-pair gradients, fixed position, and fixed color pair. Easing samples the
end of a frame: `(tick + 1 - start) / (stop - start)`. Gradient holds start at
age zero. This preserves the existing motion/landing boundaries. Zero-length
keypoints write nothing. Easing must precede actions consuming its factors.

The generated data currently contains position and color pair. Glyph, bold,
visibility and layer remain separate writers; this prototype does not yet
provide actions for every particle field. No encoded appearance or complete
ANSI packet is duplicated in the sequence.

`set_particle(e, ids, frames)` receives particle IDs and one sample per particle.
Its bulk implementation lives in `particle.odin`; `batch.odin` only generates
frame data. This consolidates the former `load_frames` entry into the existing
setter proc group without changing its algorithm. It compares
against requested engine state, fills reserved update storage directly, and
publishes its length once. Existing queued changes remain deduplicated.
Private appearance bytes are still encoded lazily by the renderer. Neither
frame generation nor keypoint evaluation mutates Engine.

Swarm owns sixteen reusable samples per input particle plus one current-frame
staging buffer. It evaluates actions when a chunk expires, never beyond a
planned lane interruption, landing transition, or completion. Phase decisions
run on refill. The existing planner, RNG ordering, final publication and
retirement remain effect-owned. Build no longer creates eleven landing color
pairs per particle; landing gradients are actions in the same chunk API.
This is bounded lookahead, not storage for the complete animation.

All production timing includes construction, chunk generation, loading,
composition, output and teardown. Moving arithmetic out of `next` is not
counted as eliminating its cost. Batching does not establish SIMD execution
across samples; scalar easing remains in the sampled profile.

## Movement experiment

The existing update queue already deduplicates particles. The renderer now
defers a crowded cell's replacement-winner search until queued moves drain.
Empty and singleton cells resolve immediately. A reusable list stores vacated
crowded cells; `CELL_UNRESOLVED` prevents duplicate entries. Layer arrays,
linear membership lookup and ordered removal remain unchanged. This is not
constant-time movement.

The first version deferred every vacated cell. Its 35-effect mean was flat,
and several effects slowed down. The current version avoids that extra work
for empty/singleton cells. Both versions and their measurements are preserved
under `/tmp/otfx-action-batch-20260926`; none of the incoming work was discarded.

## Validation and scope

- `odin check src` and optimized native/debug builds pass.
- 222/222 exact captures pass across all 37 effects.
- 37/37 effects pass the four-frame smoke matrix.
- 70 unit tests: 66 pass, including four new tests; the same four pre-existing
  allocation-test failures remain. Tests were also run with frame counters
  enabled to verify the crowded-cell winner search.
- Parity: 13 matches, 24 existing diagnostic differences, zero failures.
- Temporary allocator lifetime and its end-of-frame reset are unchanged.

Measured prototype delta versus the checkpoint: +275/-95 lines (net +180). This is an
API/performance prototype, not yet a net code reduction. The new tests cover
scalar/batched sample equivalence, chunked gradient holds, timed overlap,
bulk-load deduplication, and final cell membership after crowded departures.

The subsequent API integration moves the existing bulk loader unchanged into
the `set_particle` proc group in `particle.odin`. Swarm and the tests use that
overload; there is no second loader or new update queue. `odin check`, the
three sequence tests and six exact Swarm captures pass after the move. The
timings below describe the measured prototype; this organization-only change
was not benchmarked again.

Frozen binaries, source variants, scoped `changes.diff`, logs and profiles
are in `/tmp/otfx-action-batch-20260926`.

```sh
BENCH_MIN_SECONDS=0.3 taskset -c 2 \
  /tmp/otfx-action-batch-20260926/bench 2 swarm
```

The benchmark's `rust` label denotes the frozen checkpoint Odin binary;
`odin` denotes this experiment. Both use `-o:speed -microarch:native -debug`,
seed 1, terminal 200x50, input 190x46, unpaced output to `/dev/null`, and CPU 2.
Builds, tests and profiling do not run concurrently with timing. Two batched
samples provide a screen; small differences require confirmation.

## Final paired screen

| Metric | Checkpoint | Experiment |
| --- | ---: | ---: |
| Swarm best wall | 142.4 ms | 127.3 ms |
| Swarm mean CPU | 142.2 ms | 128.1 ms |
| Swarm peak RSS | 21,516 KiB | 22,652 KiB |
| 35-effect mean best wall | 46.680 ms | 46.434 ms |
| 35-effect mean CPU | 46.671 ms | 46.594 ms |
| Mean per-effect peak RSS | 13,585.6 KiB | 13,649.5 KiB |

All 35 frame counts match; Swarm retains 4,312 frames. The final Swarm wall
reduction is 10.6%, but aggregate improvement is only 0.53%. Geometric speedup
is 0.997x. The screen's best-wall regressions above 2% are Burn +3.6%, Print
+2.2%, Randomsequence +3.3%, Slice +2.3%, and Waves +2.0% (rounded). These
remain flagged; this is not evidence of a regression-free improvement. Burn
also regressed in the preceding targeted screen. All per-effect wall/CPU/RSS
and frame counts are in [the TSV](action-sequence-batches.tsv).

The unchanged ASM `c2be6411` reference previously measured 95.3 ms for Swarm,
with 5,041 frames. It was not rerun; choreography/frame counts differ. This
prototype is still slower. ASM prepares reusable easing tables and encoded
visuals, but advances particles and composes cells at runtime; it does not
pre-render all Swarm frames.

A diagnostic before the final bulk-queue adjustment measured update/load
60.2 ms, composition 39.4 ms, patch/emission 25.8 ms, writes 2.7 ms, and
18.4 ms of other/instrumentation work. Do not add these to or substitute them
for production wall time. The patch phase includes dirty iteration, style
encoding, glyph encoding and row marking, not just copying bytes. Candidate
updates (1,480,854) and patched cells (1,320,787) are unchanged. Deferring
winner resolution did not materially reduce composition time in this screen.

SHA-256:

- Checkpoint binary: `2cab52fdea20f46dbb353a9626a8c6d9dae00b73b379ba3eace19bd4bb334a3c`
- Experiment binary: `e450e08a6c3649ecec092157eb91694bbd4a16713abcffbbf0344b5e0ac8a969`
