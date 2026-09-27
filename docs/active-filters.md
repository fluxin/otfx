# Active effect filters and held updates

2026-09-26, uncommitted. This builds on the active-work changes and the
single-pass composition experiment. Only Beams, Bubbles, Spotlights, and Burn
changed; renderer storage, fixed-width cell packets, and public setters remain
the same. No commits or removal of earlier experiments.

## Changes

- **Beams:** a deduplicated active-appearance list replaces full-character
  appearance scans. Releasing either beam direction restarts the existing
  entry. Beam palette, fade, and final-wipe updates run only at their respective
  hold boundaries. Latest beam/wipe end ticks replace termination scans while
  preserving the original phase and final hold durations.
- **Bubbles:** visit active groups only. Within popping groups, stable-compact
  remaining members in the existing member pool after final motion, layer,
  and color publication and the required hold. Finished members no longer
  wait for the slowest member's updates. Floating visibility/symbol setup runs
  once, rainbow changes every four ticks, and pop/fade colors at their original
  boundaries. Group order and pop RNG draws are preserved.
- **Spotlights:** build row spans into the existing ordered character array.
  Candidate bits union the current light bounding boxes and the previous lit
  indices. Only candidates need exact distance/color work; previously lit
  particles still darken after departure. Overlapping lights are deduplicated.
  Dynamic nil-foreground restoration still visits all characters once on the
  Expand transition, including characters outside the light. This is a static
  input index, not a second renderer canvas.
- **Burn:** source records have `start_tick` and `next_update`. The build sorts
  ignition records by tick, then original character index. Head/tail cursors
  select started, unfinished sources. A source sleeps until its next four-tick
  palette boundary. Same-tick smoke births retain their original ordering and
  RNG draws. Smoke movement continues until arrival; smoke color changes only
  every ten ticks through its final step. Existing lifetimes and completion
  behavior are preserved.

No generic scheduler, engine sleep API, alternate color encoding, or prepared
easing system was introduced. Remaining active work is still real: Spotlight
candidates need brightness calculations; moving bubble members need motion.

## Paired full-effect measurements

Native optimized/debug binaries (`-o:speed -microarch:native -debug`), CPU 2,
terminal 200x50, input 190x46, seed 1, frame rate zero, stdout `/dev/null`.
Two samples, minimum 0.5 seconds per sample batch. Includes build and playback.
The harness's `rust` label is the frozen Odin baseline, not ASM.

| Effect | Before ms | After ms | Reduction | Frames before/after |
| --- | ---: | ---: | ---: | ---: |
| Beams | 30.4 | 22.0 | 27.6% | 890 / 890 |
| Bubbles | 65.4 | 56.8 | 13.1% | 11,658 / 11,658 |
| Spotlights | 42.4 | 38.7 | 8.7% | 780 / 780 |
| Burn | 40.8 | 25.7 | 37.0% | 3,237 / 3,237 |

All four improved in this screen. Peak RSS stayed broadly similar; Burn rose
from 14,336 to 14,404 KiB. [Full wall/CPU/RSS data](active-filters.tsv).
Unchanged effects and ASM were not rebenchmarked; these numbers are not a new
35-effect aggregate or a fresh ASM comparison.

## Validation and retained evidence

- `odin check src`, formatting of changed files, and native optimized/debug
  builds pass. Unrelated formatter-only edits were removed by restoring their
  exact pre-experiment contents after checking that they were whitespace-only.
- 79 tests: 75 pass; the same four pre-existing allocation tests fail. Existing
  Burn ignition-connectivity and Bubbles completion tests were adapted to the
  new source records and explicit active group membership.
- 222/222 standard byte-exact before/after captures across 37 effects and six
  fixtures, plus 354/354 extra cases for these four effects: input color modes,
  seeds, spotlight count/falloff/width/speed, rainbow/pop/speed/delay, beam/wipe
  holds, and smoke probabilities. **576 exact captures total.**
- 37/37 smoke checks. Parity: 13 matches, 24 existing diagnostic differences,
  zero failures.
- Production source delta: 165 added / 110 removed, net +55 lines before the
  comment-only clarification. Reduced repeated runtime work is not a claim of
  net source-line deletion.

Artifacts: `/tmp/otfx-active-filters-20260926/` contains frozen before/after
binaries and hashes, source/test snapshots and diffs, benchmark output,
captures, test/parity/smoke logs, and the scripts. `after-three` preserves the
first Beams/Bubbles/Spotlights version before Burn was added. The root `otfx`
executable was not replaced. The prefix-formatting control from the previous
profile was not brought into production.

```sh
BENCH_MIN_SECONDS=0.5 taskset -c 2 /tmp/otfx-active-filters-20260926/bench 2 beams bubbles spotlights burn
```
