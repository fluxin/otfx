# Native rounding and casting experiments

SIMD rounding was restored at the user's request after the measurements below.
The neutral helper name `round_to_int` and Binarypath pending-array cleanup remain.
Native and cast-only source snapshots and binaries are preserved for review.

The native experiment used `math.round` in `round_to_int` and `linalg.round` in
`rounded_coord`, with no `core:simd` dependency in geometry. The helper was renamed
from `round_half_even` because native rounding has a different halfway rule.
Call sites were renamed mechanically; no effect phase logic was rewritten.
The cast-only version is isolated under `/tmp/otfx-native-rounding-20260926/cast/`.
The original SIMD source and binary are also preserved. No commits were made.

## Library and semantics

Inspected the installed Odin `dev-2026-09-nightly:a2fb372` source:

- `core/math/math.odin:803`: `round_f64`, selected by `math.round`, rounds halfway
  values away from zero using the floating-point representation.
- `core/math/linalg/extended.odin:426`: `linalg.round` applies `math.round` to each
  component. It does not promise the paired SIMD instruction used previously.
- The previous `simd.nearest` rounds halfway values to the even integer.
- Plain `int(x)` truncates toward zero. This changes non-tie fractions too.

| Input | SIMD nearest/even | Native round | Cast |
|---|---:|---:|---:|
| 2.5 | 2 | 3 | 2 |
| -2.5 | -2 | -3 | -2 |
| 1.9 | 2 | 2 | 1 |
| -1.9 | -2 | -2 | -1 |

These conversions affect coordinates, duration steps, palette selection, and
RGB quantization. A byte mismatch does not establish a visual defect, and matching
final text does not establish identical animation duration or choreography.

## Behavior

The 222-case matrix uses 37 effects, six fixtures (plain, no-color, input SGR
always/dynamic, xterm glyphs, and clipped/wrapped input), seed 42, virtual clock,
40x12 unless the fixture overrides it, and one-second Matrix/Thunderstorm windows.
Terminal streams were replayed into cell state including glyph, foreground,
background, and bold. NUL padding is ignored; final cursor position is compared.
This is a deterministic terminal-state diagnostic, not a human review of all
visual phases. Differing frame counts are reported rather than treated as an
automatic failure.

| Check | Native round | Cast |
|---|---:|---:|
| Byte-identical captures | 112/222 | 65/222 |
| Identical visible frames | 112/222 | 65/222 |
| Same frame count | 209/222 | 155/222 |
| Same final styled screen | 222/222 | 219/222 |
| Same final glyphs and positions | 222/222 | 222/222 |
| Same final cursor | 222/222 | 222/222 |

Native rounding preserves every final screen in this matrix. Thirteen cases
change frame counts, by one to seven frames. Casting changes 67 case durations;
the plain Swarm case grows from 2,024 to 2,737 frames. Cast Spotlight ends with
different styling in three fixtures: truecolor channels differ by one, and one
xterm cell changes palette index 229 to 228. All final glyphs and cursor positions
still match. These differences are outside a mere ANSI-packet comparison.

[Native capture table](rounding-native-captures.tsv),
[cast capture table](rounding-cast-captures.tsv).

## Performance

Each variant has its own full before/after benchmark against the same frozen SIMD
binary. Identical compiler options: `-o:speed -microarch:native -debug`, CPU 2,
seed 1, terminal 200x50, dense input 190x46, unpaced `/dev/null` output, three
samples, minimum 0.3-second batches, wait4 CPU and RSS. No build, test, replay,
or profile ran alongside measurement. Matrix and Thunderstorm use separate
one-second wall-clock diagnostics and are excluded from the 35-effect mean.
ASM was not rerun. The harness calls the before Odin binary `rust`.

Frame counts can change: these are end-to-end completion times, not proof of
equal-work throughput. The per-effect tables include frame counts to expose
shortened or lengthened workloads. Raw harness summaries retain its labels.

### Native round

```
throughput summary (35 effects, unweighted means):
  best wall 48.1ms / 50.2ms, mean CPU 48.2ms / 50.3ms, peak RSS 13.2 MiB / 13.3 MiB
  geometric wall-speedup 0.97x, Odin/Rust CPU 1.04x, Odin/Rust RSS 1.00x
```

[All effects](rounding-native-benchmark.tsv).

Changed benchmark frame counts: fireworks 1516→1515, swarm 4312→4314.

Initial best-wall slowdowns over 2% (not independently screened):

| Effect | SIMD ms | Variant ms | Change |
|---|---:|---:|---:|
| binarypath | 240.6 | 250.7 | +4.2% |
| blackhole | 77.5 | 80.8 | +4.3% |
| bouncyballs | 47.2 | 49.1 | +4.0% |
| bubbles | 73.8 | 77.9 | +5.6% |
| burn | 44.0 | 46.7 | +6.1% |
| crumble | 55.9 | 58.0 | +3.8% |
| errorcorrect | 17.2 | 17.6 | +2.3% |
| expand | 35.2 | 41.3 | +17.3% |
| fireworks | 117.2 | 126.2 | +7.7% |
| laseretch | 59.0 | 60.6 | +2.7% |
| middleout | 27.9 | 29.0 | +3.9% |
| orbittingvolley | 31.5 | 32.3 | +2.5% |
| pour | 24.8 | 26.2 | +5.6% |
| rain | 23.2 | 24.2 | +4.3% |
| rings | 104.0 | 111.4 | +7.1% |
| scattered | 59.9 | 63.4 | +5.8% |
| slice | 13.2 | 15.1 | +14.4% |
| slide | 29.2 | 30.5 | +4.5% |
| swarm | 150.7 | 158.2 | +5.0% |
| unstable | 66.9 | 70.8 | +5.8% |
| vhstape | 38.6 | 39.6 | +2.6% |

### Cast

```
throughput summary (35 effects, unweighted means):
  best wall 48.4ms / 49.0ms, mean CPU 48.5ms / 49.2ms, peak RSS 13.2 MiB / 13.3 MiB
  geometric wall-speedup 0.98x, Odin/Rust CPU 1.01x, Odin/Rust RSS 1.01x
```

[All effects](rounding-cast-benchmark.tsv).

Changed benchmark frame counts: binarypath 1932→1935, blackhole 1743→1717, bubbles 11658→11650, errorcorrect 5221→5220, expand 302→301, fireworks 1516→1507, middleout 235→234, orbittingvolley 1156→1155, slide 375→374, spotlights 780→776, swarm 4312→4430.

Initial best-wall slowdowns over 2% (not independently screened):

| Effect | SIMD ms | Variant ms | Change |
|---|---:|---:|---:|
| burn | 44.4 | 45.8 | +3.2% |
| middleout | 27.9 | 33.0 | +18.3% |
| pour | 24.7 | 26.7 | +8.1% |
| rain | 23.2 | 26.7 | +15.1% |
| rings | 104.0 | 112.5 | +8.2% |
| slice | 13.2 | 16.3 | +23.5% |
| smoke | 18.2 | 18.7 | +2.7% |
| wipe | 8.3 | 8.5 | +2.4% |

## Longer native-rounding checks

Five samples per effect, minimum one-second batches, same binaries/CPU/input.

| Effect | SIMD ms | Native ms | Change | Frames SIMD/native |
|---|---:|---:|---:|---:|
| expand | 37.5 | 43.3 | +15.5% | 302/302 |
| slice | 13.3 | 15.1 | +13.5% | 368/368 |
| fireworks | 117.2 | 126.1 | +7.6% | 1516/1515 |
| binarypath | 240.0 | 250.7 | +4.5% | 1932/1932 |

The native library calls were already inlined in the optimized binary: symbol
and call-site inspection found no `round_f64`, `round_to_int`, or `rounded_coord`
calls. Adding an inline annotation is therefore not an explanation for recovery.
The installed library uses scalar bit manipulation for rounding; `linalg.round`
applies it per component, whereas the previous source used paired SIMD nearest.

The native variant does not meet the requested condition of no significant
performance side effects in these runs. SIMD has been restored in the source
and executable with the completed publication and pending-array cleanups.
Neither experiment was discarded; source snapshots remain under `/tmp`.

## Validation and artifacts

Native source check/build, preview/accuracy/phase checks, 37-effect smoke, and
non-ASM parity pass (13 matches, 24 diagnostic differences, zero failures).
Tests are 60/64: the same four pre-existing allocation failures remain. The
rounding test now states the native half-away rule and covers both scalar and
coordinate conversion; other assertions were not weakened. The cast variant
has the full capture/replay and 35-effect CLI coverage above, not a claim that
the native-rounding unit contract passes for truncation.

The benchmark harnesses, frozen source/binaries, capture/replay scripts/results,
test logs, and scoped diff are under `/tmp/otfx-native-rounding-20260926/`.
Full source snapshots preserve the previous implementation for review.

## Binarypath pending-array follow-up

After the rounding comparisons, Binarypath's build now sizes `pending` to the
known source-particle count and fills `pending[i] = i` in its existing loop.
This replaces incremental append/growth without adding a temporary collection
or changing pending order, random draws, motion, collapse, or final wipe.

A separate native-rounding before/after comparison (same native/debug build
flags, CPU 2, five samples, minimum one-second batches) measured best wall
250.5 to 249.1 ms, mean wall 251.6 to 251.4 ms, mean CPU 250.9 to 250.7 ms,
and peak RSS 20,992 to 20,864 KiB. Both produced 1,932 frames. The end-to-end
timing is effectively unchanged; this does not recover the rounding regression.
All six Binarypath captures are byte-identical. Source check/build pass; tests
remain 60/64 with the same four allocation failures. No assertions were changed.
Frozen binaries, the scoped source diff, captures, and benchmark log are in
`/tmp/otfx-binarypath-pending-20260926/`. Nothing was committed.
