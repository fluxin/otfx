# Thunderstorm recursive branching

The implementation remains in `src/effects/thunderstorm.odin`. It generates
recursive branches in scalar batches and replays a flat segment sequence.
There is no explicit SIMD implementation.

Each generation batch advances the live branch tips once. Random words are
filled in bulk using Odin's native RNG. Branch probability follows Python's
5% initial chance, one percentage point reduction for a child, and reset to 5%
when that child returns. A side branch departs one column from its parent and
cannot fork on its first row; subsequent rows can fork recursively.

Generation records contiguous branch spans and child insertion points in the
frame arena. A stack flattens those spans into Python's depth-first reveal
order. Once the final segment count is known, the engine character storage,
strike IDs, and replay array are reserved before filling. Existing capacity
is reused. The generation scratch does not survive into playback.

Playback reveals the existing sequence in batches of one to three characters.
Only the revealed prefix enters the renderer's candidate list. Retiring a
strike hides its segments and clears both the sequence and reveal cursor.

The old quadratic pool bound only covered nonrecursive branches. Storage now
grows from the generated count without dropping branches at a fixed limit.
Recursive geometry can grow rapidly on tall canvases; this change preserves
that behavior rather than introducing a hidden population cap.

## Validation

Accuracy oracle: original Python TerminalTextEffects checkout
`7a91dd9ca6ee0c4f4b1484efee0ecac1bb84104e`.
Performance oracle: Rust ttfx checkout
`54d21f046f22512b113056a1964077d7b7bf04cc`, using its existing release binary.
Before-build baseline: Odin revision
`1dc9033c6f0dcd7200db5ae386e7824e23927fe4`.

- `odin check src` and optimized build pass.
- All 10 tests pass. Three Thunderstorm tests cover nested replay order,
  geometry across 320 seeded cases, growth beyond the old capacity, scratch
  lifetime, allocation-free segment reveal, pool reuse, and retirement.
- Fifteen generated decision sequences were supplied to the original Python
  `setup_lightning_strike` implementation: heights 1/12/24/50/100, seeds
  1/42/123. All 6,279 coordinates, symbols, and child insertion positions
  matched. This checks choreography under equal decisions, not RNG parity.
- Three 40x12, 12-second logical-clock captures finish with exactly Python's
  final glyphs and colors; repeated Odin captures are identical. Frame counts
  are 924/911/911 for seeds 1/42/123, and are diagnostic only.
- Tiny and narrow canvases, no-color output, and the existing dynamic-color
  final state remain unchanged from the baseline.

Generation plus flattening, optimized scalar build, 64 seeds per height:

| Canvas rows | Mean segments | Largest strike | Mean generation time | Largest observed time |
| ---: | ---: | ---: | ---: | ---: |
| 24 | 47 | 128 | 1.2 us | 3 us |
| 50 | 193 | 519 | 3.0 us | 7 us |
| 100 | 1,597 | 5,323 | 49 us | 456 us |
| 160 | 17,080 | 65,185 | 2.34 ms | 10.48 ms |

These diagnostic timings include temporary allocation and are not a renderer
or end-to-end speedup. Python's independently seeded sample averaged 48 and
208 segments at heights 24 and 50 respectively; exact random streams differ.

## Paced resource comparison

Measured 2026-09-25 using the maintained `bench.make_input`, `command_make`,
and `run_command` helpers: two complete runs per binary, reversed order on the
second pass, seed 1, storm-time 12, frame rate 60, terminal 200x50, dense 190x46
input, stdout `/dev/null`. CPU is wait4 user plus system time; RSS is the
maximum across children. Terminal emulator cost is excluded.

| Metric | Before | Recursive batches | Rust |
| --- | ---: | ---: | ---: |
| Mean CPU per completed animation | 58.151 ms | 56.925 ms | 283.369 ms |
| CPU duty | 0.323% | 0.338% | 1.719% |
| Peak RSS | 11,368 KiB | 13,656 KiB | 141,596 KiB |
| Mean wall duration, diagnostic | 17.977 s | 16.840 s | 16.481 s |

The richer branches retain approximately the same CPU duty as the old version
and add about 2.2 MiB peak RSS in this sample. CPU per animation is about 80%
lower than Rust and peak RSS about 90% lower. Two repeats are an indicative
comparison, not a confidence interval. The change is retained for richer
choreography at a small measured resource cost, not as a speedup over the old
Odin implementation.

The animation performs different random work and can finish at different
wall times. Wall duration is diagnostic; it is not a throughput speedup.

This change is scoped to recursive branch generation and replay. The earlier
review's full-text flash, dynamic default-color restoration, spark cooling,
and particle-tail differences remain separate follow-ups.
