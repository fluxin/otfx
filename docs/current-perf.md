# Current performance profile

2026-09-26. Profiles include the active-effect changes and the uncommitted
single-pass composition experiment. They do not describe the older two-pass
renderer. No production code was changed during this investigation.

## Findings

There is no demonstrated single change that closes the ASM gap. The new
shared finding is the dependency between prefix construction and copying the
prefix into a cell. It is significant in stationary, appearance-heavy effects,
but it does not explain Middleout or all of Swarm.

| Workload | Observed sampled user-cycle cost | Implication |
| --- | --- | --- |
| Beams | Appearance update procedure 44.25% self; cell packet copy path about 19.5%; sorting functions/comparators also visible in build | Visit only active appearance work, publish on palette boundaries, and investigate fresh-prefix copy cost. Build grouping is a separate cost. |
| Burn | Effect dispatch/update 55.60% self; cell packet copy path about 11.9% | The fire loop still scans every character, including unstarted and retired entries. Fire colors change every four ticks; smoke colors every ten. |
| Spotlights | Effect update 64.78% self; HSL brightness adjustment 15.90% self; cell packet copy about 14.1% | The changed-illumination path still scans every character, computes distances, and submits unchanged dark appearances. The setter's comparison alone has 9.41% attributed samples. |
| Scattered | Effect dispatch/update 25.41% self, with another 7.94% in easing and substantial libm samples | Active motion remains expensive; particles sharing duration use identical easing inputs at a given tick. Gradients have only a few discrete steps but are recalculated every active tick. |
| Swarm | Effect dispatch/update 26.77% self; batch generation 7.64%, plus easing/libm; renderer/lifecycle caller 37.25% | Bounded generation still computes every frame sample. Publication, coordinate/color comparisons, and queue work remain after removing the staging pass. |
| Bubbles | Effect update 42.30% self; `exp2` 8.87%; dirty-bit iteration 7.56% | Popping groups continue visiting members that have finished while other members remain active; symbol/color assignments repeat between discrete transitions. |
| Middleout | Binary-search source lines dominate the renderer sample; copying/shifting is also visible | Ordered membership maintenance is the remaining issue. The separate stack-counter experiment measured insertion shifts rising from 18.4M to 41.7M with one-pass draining. |
| Binarypath | Renderer/lifecycle caller 58.21% self; effect update 32.21% | Its large update volume explains the useful one-pass improvement; the profile does not support calling output syscalls the dominant cost. |
| Decrypt | Effect dispatch/update 37.30% self; renderer/lifecycle caller 35.57%; RNG functions visible in build | Fast frames repeat a symbol/appearance selection for two ticks, and later color transitions are held for five ticks. Build RNG is real full-lifecycle cost. |
| Unstable | Renderer/lifecycle caller 58.93% self; effect update 22.69%; `exp2` 7.08% | The earlier effect skips helped, but native easing and stack maintenance remain. |

Self percentages are disjoint at the top-level symbol table. Inline attribution
inside a parent is a subset, not an additional percentage to add to that
parent. `main::run_effect_once` includes inlined renderer and lifecycle code;
it is not a pure composition timer. Source lines and error-check symbols are
sampling/debug attribution, not evidence that runtime errors occurred.
[Exclusive symbol samples](current-perf.tsv).

## Prefix write/read dependency

`encode_particle` resolves the winning appearance. If dirty, it encodes that
appearance's 43-byte prefix and immediately copies it into the cell. Encoding
uses template stores followed by individual decimal-field stores. The copy
uses a 32-byte vector load plus 8-, 2-, and 1-byte tail loads. Samples cluster
around those loads, immediately after the prefix writes. A load blocked by
earlier smaller stores is a plausible explanation; sampling alone cannot
distinguish every source of load latency.

A hardware-counter control runs 30 full animations per effect with and
without color. These are separate diagnostic workloads, not an output-preserving
optimization or throughput comparison against ASM.

| Effect | Store-to-load conflicts, color / no color | Cycle reduction without color |
| --- | ---: | ---: |
| Beams | 82,466,755 / 46,341,657 | 12.4% |
| Spotlights | 55,606,890 / 20,203,697 | 7.5% |
| Middleout | 14,118,446 / 9,450,129 | 2.0% |

Counters are `ls_bad_status2.stli_other:u`, with cycles, instructions,
`ex_no_retire.load_not_complete:u`, and cache misses. Color removal also skips
encoding and reduces emitted bytes, so it does not isolate forwarding stalls
as the sole cause. It does demonstrate that this path matters much more for
appearance-heavy effects than for Middleout.

The least invasive control is to stop initializing all 43 prefix bytes before
`packet_color` overwrites both 19-byte color fields. Initialize only the five
style bytes, retaining both color-field writes and all output semantics. This
control is isolated under `/tmp`, not applied to production source.

The control did **not** produce a meaningful win: paired two-sample screens
gave Beams 30.3 to 30.1 ms, Spotlights 42.4 to 42.3, Burn 40.5 to 40.6, and
Middleout 26.7 to 26.6. All 222 exact captures match. These results do not
justify claiming the redundant template initialization explains the hotspot.
The candidate is preserved as `prefix-control/src` and `prefix-bin`, with
`prefix-screen.log` and `capture-prefix.log`; production source is unchanged.

The cached ASM revision `c2be6411` does not send raw one-byte RGB channels to
the terminal. `asm/engine/visual.asm:sgr_rgb` emits decimal ANSI fields using
`dec3_table`: 256 entries, each holding up to three decimal digits and a length
byte. Its visual pool retains complete encoded sequences for reuse. Odin's
`Color` already has three `u8` channels, but `packet_decimal` computes its
three decimal digits when a dirty appearance is encoded. A decimal lookup
table is a separate candidate, not measured in this investigation. Raw hex
bytes would not be equivalent terminal output.

## Next work justified by the profile

1. Remove inactive scans and repeated palette-step work in Beams/Burn/Bubbles.
   Keep emission, RNG order, final publication, and completion timing intact.
2. Treat equal motion inputs as shared work where they actually occur. For
   example Scattered's `(tick, duration, easing)` is independent of the
   particle's endpoints. This is shared frame computation, not a reason to
   replace native easing or precompute entire animations.
3. For the renderer, investigate the fresh-prefix write/read dependency and
   crowded-stack maintenance separately. The one-pass result shows that fewer
   traversals can increase total stack work.

Explicit shared appearance IDs already provide a way for effect-owned
palettes to reuse encoded prefixes. That is a candidate to measure, not proof
that every effect can share a full appearance: input background/bold and
dynamic color semantics must remain correct. No automatic global appearance
deduplication or new public API is proposed here.

## Reproduction

Frozen production binary: `/tmp/otfx-current-perf-20260926/otfx`, SHA-256
`1957f02628bec8680d1575d94577cac7a45d31bcab859590efb99ec49879aad7`.
It matches the current source and the previous single-pass experiment binary.
Built with `-o:speed -microarch:native -debug`; CPU 2, 200x50 terminal,
190x46 input, seed 1, frame rate zero, stdout `/dev/null`.

`profile.sh` records `cycles:u` at 999 Hz with 8192-byte DWARF call stacks.
It repeats full CLI lifecycles: 15 Binarypath, 25 Swarm, 90 Middleout/Beams,
50 each of Scattered/Unstable/Spotlights/Bubbles/Burn/Decrypt. No lost samples
were reported. Raw recordings, self/inclusive/source reports, Beams assembly,
hardware-counter logs, and scripts are preserved in the artifact directory.
Builds and tests did not run during profiling/measurement.

An additional six-effect diagnostic (10 complete runs each of Scattered,
Swarm, Middleout, Spotlights, Beams, Burn) recorded 15.66B user cycles,
45.96B instructions, 8.04B branches, 138.15M branch misses, and 77.08M cache
misses. These are current Odin counters only, not a matched ASM counter ratio.
They do not rule out memory stalls.
