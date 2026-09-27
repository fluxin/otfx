# Outlier audit — 2026-09-26

The common costs are repeated motion calculations, appearance publication while a sample is held, and maintaining sorted cell occupants. They need separate experiments: the largest stack change previously accelerated Middleout but regressed the aggregate. No production source was changed by this audit.

## Measurement

Profiled the ten largest absolute positive gaps, using the production `before_ms` column in `deferred-interior.tsv` and the recorded ASM column in `scoped-asm-comparison.tsv`. The complete ranking is in `outlier-audit-20260926.tsv`. These timing columns are prior benchmark results, not timings collected under perf. Production mean: 33.1514 ms; recorded ASM mean: 30.7629 ms (production 7.8% slower). ASM revision: `c2be6411d3e4d5002f160dc0cbd10af7cb3a3889`; this audit did not fetch/rebuild/rebenchmark ASM.

Fresh samples use `/tmp/otfx-held-bulk-20260926/after`, SHA256 `8c31eb2437a47700965b9ca0c2816ac99be9a628bc695eed8ce9fdae56b0b067`, built with `-o:speed -microarch:native -debug`, assertions retained. Its frozen `after-source/src` matches current `src`. Every repetition runs the real CLI including build, playback and cleanup, on CPU 2, seed 1, frame-rate 0, terminal 200x50, dense input 190x46, stdout `/dev/null`.

Artifacts: `/tmp/otfx-outlier-audit-20260926/{profile.sh,profile.log,<effect>.data,<effect>-self.txt,<effect>-inclusive.txt}`. Sampling: `perf record -e cycles:u -F 999 --call-graph dwarf,8192`; 29–145 complete process runs per effect, sequentially, targeting about three seconds of unprofiled work. All ten reports have zero lost samples. Sample shares exclude kernel cycles; DWARF sampling adds overhead. They are diagnostic shares, not guaranteed wall-time savings. Inline child attribution sits inside its enclosing symbol: do not add parent and child percentages. `bounds_check_error (inlined)` attribution identifies check sites, not executed failures. Unresolved libm addresses remain unnamed.

## Largest gaps and fresh findings

| Effect | Production ms | Recorded ASM ms | Gap ms | Fresh sampled evidence and source finding |
|---|---:|---:|---:|---|
| Scattered | 44.9 | 24.8 | 20.1 | Easing plus prominent libm sites about 18.7%; removal 6.9%, insertion 6.0%. `scattered_next` already uses active indexes and held-color guards, but evaluates easing per particle each tick. Share factors only among identical duration/tick/ease inputs; duration duplication has not yet been counted. |
| Middleout | 25.9 | 8.4 | 17.5 | Binary searches 38.8%: removal 21.8%, insertion 17.0%. Shared axis motion already exists. Stack maintenance is the primary target, not effect easing. |
| Fireworks | 72.8 | 62.5 | 10.3 | `next_frame` self and inline work 54.2%; external `exp2` another 6.7%. Launch origin, age, apex duration and position are identical within a shell, but calculated per member. Later paths differ per particle. Phase-constant glyph/layer and held fall colors are also republished. |
| Spotlights | 36.8 | 26.6 | 10.2 | Brightness conversion 20.8%; sqrt 8.8%; generic bitset set 8.7%, resize helper 1.5%, iterator 4.3%. Existing spatial filtering is present. Fixed bright colors are converted RGB-to-HSL repeatedly; distances take a sqrt for every spotlight before choosing the nearest. |
| Blackhole | 64.4 | 54.9 | 9.5 | `blackhole_next` self and inline work 50.7%. Shared duration factors already exist. Collapse scans non-ring particles merely to hide them again; explosion continues scanning completed returns. Move invariant publication to phase boundaries and retain only active work. |
| Swarm | 104.8 | 95.4 | 9.4 | `next_frame` self/inline 27.2%, `sequence_batch` 8.3%, easing 2.0% plus prominent libm sites 6.2%. It already batches motion chunks and compacts active indexes. Changes belong in the existing sequence path; a second batching abstraction would duplicate it. |
| Slide | 20.8 | 12.7 | 8.1 | `next_frame` self/inline 47.1%; appearance equality alone 6.2%, gradient sampling 3.3%. It recalculates and submits held gradient samples and visits exhausted release groups. Movement and color have different completion times. |
| Expand | 24.4 | 16.6 | 7.8 | Binary searches 14.8%; appearance equality 8.6%; easing 4.8%. Its 11 color samples are already built, but held samples still reach the appearance setter. Active compaction already exists. |
| Decrypt | 24.5 | 16.9 | 7.6 | Render appearance lookup 9.3%; packet copy path about 8.4%; effect loop self 19.6%. Earlier held-publication optimization is already present; remaining glyph changes still rewrite style bytes. |
| Waves | 22.6 | 15.7 | 6.9 | Render appearance lookup 13.4%, packet copy 8.3%, UTF-8 encoding 3.2%. Wave samples are prepared, final fade has a sample guard, but wave-phase symbol/style are submitted each active tick. |

These ten positive gaps sum to 107.4 ms, or 3.07 ms of the 35-effect arithmetic mean. That is a prioritization budget, not recoverable savings: other effects beat ASM, and random effects do not necessarily generate identical frame counts/work. The unusually high Pour baseline is not used to claim a new optimization opportunity.

## Recommended independent screens

1. **Identical motion inputs:** Scattered first; Fireworks launch second. Calculate each identical easing input once per frame, retain per-particle interpolation where endpoints differ. Fireworks can share the whole launch position. Use flat duration/group data established at build; do not precompute whole animations or change the public renderer API. Count unique versus total factor evaluations before deciding whether Expand or Swarm benefits. Swarm must retain its current planner/RNG ordering.
2. **Cell membership:** Middleout and Expand, with Binarypath as the regression control. Array-indexed previous/next links permit removal of a known particle without searching or shifting. An unsorted list plus cached top only scans survivors when the winner needs replacement, once after queued changes. This is a candidate, not a measured win in our engine. Keep the current sorted-array version for comparison; include links' memory cost and crowded-list traversal. See the existing reverse-search, cell-batch-merge and deferred-removal reports: reverse linear search lost, full batching lost globally, deferred interior compaction roughly tied globally.
3. **Stop publishing held/invariant values:** Fireworks, Slide and Expand, then Waves and Blackhole. Detect timeline sample/phase changes before constructing an appearance or invoking its setter; keep setter guards for callers. Do not add due-time buckets or more prepared private appearances without evidence. Preserve final pose/color/layer publication, Dynamic/Always input-color behavior, and ticks. Prior prepared-gradient and prefix-split experiments are not evidence of a win here.
4. **Spotlights math and fixed candidate storage:** prepare each immutable source color's HSL once, retaining the current lightness adjustment and conversion; this removes only the RGB-to-HSL portion of the 20.8%, not all color math. Compare squared distances first and take one sqrt where falloff needs it, preserving the terminal aspect-ratio metric and checking boundary rounding. Use the existing fixed-size bit-array invariant to avoid generic growth checks. Measure these separately.
5. **Renderer content granularity:** Decrypt/Waves are the clearest controls for glyph-only changes still going through appearance lookup and prefix copying. Investigate whether existing content flags can distinguish glyph from appearance changes without per-cell duplicate appearance state. Cell winner changes still require the complete packet. This is a shared opportunity, but extra state/branches may cost moving effects; do not assume a faster copy alone removes upstream work.

## Why the linked list is not a search on every movement

Current `src/engine/render.odin` has a top-pop fast path; an interior removal binary-searches the sorted key then calls `ordered_remove`, shifting the tail. Insertion likewise maintains full order.

The reference's `asm/engine/render.asm:629` indexes `previous` and `next` directly by the departing particle ID and reconnects those neighbors. Its list order is unrelated to layer order. Removing a covered particle requires no winner scan. Removing a crowded cell's winner queues that cell once; `cell_rewin` at line 681 scans the remaining occupants after changes. Insertions prepend and compare against the cached winner. The benefit is avoiding repeated search/shift work; the tradeoff is link storage, dependent loads and potentially expensive winner scans. It is not universally superior to a contiguous sorted array.

## Gates for any implementation

No implementation, timing claim for a candidate, or correctness gate is implied by this audit. Screen changed effects against frozen production first; retain a full 35-effect run for shared engine changes and final acceptance, with CPU/RSS and frame counts. Use the capture matrix and color/phase controls; report the four existing allocation-test failures separately rather than claiming a clean baseline. Production source and the root executable remain unchanged; nothing was committed.
