# Frame-count audit after checkpoint 3850833c

2026-09-26. Production source is checkpointed at `3850833c` (JJ change
`xqnwkxsm`). It includes the held-publication and bulk-fill changes. The
generated `tests.bin` is outside that checkpoint. This audit has not modified
production source or created another commit.

Odin emits more frames than the recorded ASM c2be6411 comparison in 11 of
35 finite effects, the same number in 14, and fewer in 10. This is not a
global renderer multiplier: both run loops emit once for each successful
effect step. Dirty cells and row emission do not add effect ticks.

[Complete frame-count classification](frame-count-audit.tsv).

## Confirmed scheduling bug: random interval-loop bounds

An Odin interval loop reevaluates its upper bound on each condition check.
Consequently, `for _ in 0 ..< rand.int_range(...)` draws a new random release
limit throughout the batch. Python's `range(random.randint(...))` evaluates
the count once; the corresponding ASM saves one draw and decrements it.

A native optimized probe that returns the constant limit five records six
bound evaluations for the interval expression, versus one when the limit is
stored before the loop. The effect correction is simply:

```odin
batch_count := rand.int_range(1, s.volume + 1)
for _ in 0 ..< batch_count {
    // Existing release body.
}
```

Eight sites in seven effects are affected:

- Spray particle release: `src/effects/spray.odin:202`.
- Beams group release: `src/effects/beams.odin:446`.
- Bouncyballs release: `src/effects/bouncyballs.odin:159`.
- Crumble vacuum release: `src/effects/crumble.odin:317`.
- Overflow row advance: `src/effects/overflow.odin:224`.
- Rain release: `src/effects/rain.odin:187`.
- Matrix column/rain release: `src/effects/matrix.odin:512` and `:623`.

Repeated draws bias wider ranges toward smaller batches, stretching launches
over more frames. They also consume extra RNG values and alter later choices.
Rain's range of one or two has the same batch-size probabilities either way,
but still consumes a different sequence. Fixing the bound is a semantic
correction even where the frame count or timing does not decrease.

## Isolated correction measurements

Only the eight bound expressions were changed in a copy under `/tmp`.
Both binaries use `-o:speed -microarch:native -debug`. CPU 2, 200x50 terminal,
190x46 input, seed 1, unpaced complete CLI lifecycle, stdout `/dev/null`;
three samples, minimum 0.5 seconds per sample. No concurrent builds/tests.
ASM figures below are the existing recorded reference, not a new ASM run.

| Effect | Checkpoint frames | Corrected frames | ASM frames | Before → corrected wall |
| --- | ---: | ---: | ---: | ---: |
| Spray | 1,253 | 670 | 661 | 23.9 → 23.4 ms |
| Beams | 890 | 785 | 732 | 14.1 → 14.1 ms |
| Bouncyballs | 10,393 | 9,179 | 9,093 | 35.8 → 35.1 ms |
| Crumble | 2,159 | 1,920 | 1,835 | 45.6 → 45.2 ms |
| Overflow | 164 | 178 | 306 | 10.9 → 11.1 ms |
| Rain | 4,736 | 4,761 | 4,737 | 18.0 → 17.9 ms |

[Full wall, CPU, RSS, and frame observations](frame-count-loop-control.tsv).
The large frame-count reduction produces only modest runtime savings. The
same particles still have motion/color lifetimes, now overlapping in fewer
frames. Therefore fewer frames must not be presented as an equivalent increase
in renderer throughput. This six-effect screen is not a new 35-effect result.

The isolated build passes 81/85 tests with the same four existing allocation
failures. Forty-two small-input controls cover all seven effects, three existing
color modes, and two seeds: final canvas packet bytes and cleanup match the
checkpoint. Matrix uses a virtual clock and one-second rain; no Matrix
throughput claim is made. Intermediate frames intentionally change with the
corrected launch schedule; these checks do not assert identical choreography.

## Other sources of different counts

The engines use different RNGs: Odin's default is ChaCha8; ASM uses
xoshiro256++ with its own integer/shuffle helpers. Seed 1 does not give the
same random paths, delays, grouping, or graph. Several effects also consume
draws in different orders. For example, Spray chooses start color before speed
in Odin and speed before start color in ASM. Exact remaining differences cannot
be attributed to rounding solely from a frame-count comparison.

The common line-path duration rule is nearest-even rounding of aspect-corrected
distance divided by speed in both engines. No blanket floor/ceil or double-tick
error was found. Odin also clamps many durations to at least one tick; zero-step
paths and exact phase boundaries remain useful targeted controls.

- **Scattered, Unstable, Binarypath, Fireworks, Blackhole, Bubbles,
  Errorcorrect:** random targets, groupings, speeds, or launch schedules feed
  their completion conditions. The precise seed-1 deltas remain unisolated.
- **Smoke:** completion includes the maximum BFS arrival depth of a random
  weighted spanning tree plus the color tail. Different tree/root choices can
  change duration without extra renderer work.
- **Overflow:** random cycle count and delays matter in addition to the loop
  bug. Its much shorter baseline is not evidence of twice-as-fast rendering.
- **Decrypt, Burn, VHS tape:** random typing/scene holds, smoke tails, or glitch
  returns affect completion. Existing fixed hold lengths are deliberate.
- **Spotlights:** Odin generates fresh random targets as paths finish. ASM
  builds eleven targets with a minimum-distance rule and loops them. The
  position when search ends changes the convergence duration. This is a
  choreography difference, not just renderer bookkeeping.
- **Swarm:** the planned follower rule skips completed or already-advanced
  followers before drawing coordination probability. ASM/Python draw for every
  other swarm member and may reactivate its path. This deserves a phase trace;
  do not attribute all 729 fewer frames to RNG or call it a performance win.
- **Laseretch (+1):** small-input controls reproduce exactly one extra frame
  independently of seeds 1/42, with both one glyph and ten glyphs on a 12x4
  canvas. Default spark cooling gives 141/140 and 159/158 frames (Odin/ASM);
  cooling of one gives 55/54 and 73/72. The latter makes the source cooling
  lifetime dominate instead of the spark lifetime. Odin retains sources until
  the update after their last held sample; sparks likewise retire after their
  last held color. Do not remove a terminal frame blindly: spark hiding is an
  observable final update and requires a canvas comparison. This is a bounded
  lifecycle issue, not a plausible explanation of the aggregate timing gap.
- **Synthgrid (-2):** expansion/collapse completion checks remain candidates.
  A 12x4 control with `--max-active-blocks 1` gives 71/72 frames for seed 1
  and 71/73 for seed 42, for both one and ten input glyphs. The changing delta
  does not isolate a deterministic two-frame error. Separately, playback scans
  every canvas cell, skips inactive cells via `start_ticks`, and republishes
  each two-tick generation sample twice. Those are concrete redundant-work
  candidates that can be measured without changing the phase schedule or RNG.

The remaining source classifications are hypotheses or identified policy
differences, not proofs that every recorded frame delta is fully explained.
Priority is the proven random-bound correction, then Swarm follower semantics
and targeted completion-boundary controls. The current renderer representation
does not need to change to address any of these.

## Evidence

- Probe, isolated corrected source/binary, benchmark log, tests, and 42 final
  canvas controls: `/tmp/otfx-frame-audit-20260926/`.
- Baseline binary: `/tmp/otfx-held-bulk-20260926/after`.
- ASM source snapshot: `/tmp/ttfx-asm-c2be6411/asm/`; local Git resolves
  `c2be6411` to `c2be6411d3e4d5002f160dc0cbd10af7cb3a3889`.
- Counterparts inspected: Python `effect_spray.py`, `effect_beams.py`,
  `effect_bouncyballs.py`, `effect_crumble.py`, `effect_overflow.py`,
  `effect_rain.py`, `effect_matrix.py`, and `effect_swarm.py`; ASM effect
  release loops, `asm/lib.asm`, `asm/engine/motion.asm`, and `asm/utils/rng.asm`.
