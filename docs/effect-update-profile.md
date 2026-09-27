# Effect updates and the remaining ASM gap

Baseline investigation. The resulting Odin effect-side changes and their
measurements are in [effect-active-work.md](effect-active-work.md).

Profiled 2026-09-26 after restoring the flat sorted stack. The restored
`src` tree matches the frozen pre-bulk-sort source byte for byte. `odin check`
and optimized native/debug build pass. No effect code was changed in this
investigation. The linked-list experiment was deferred in favor of effect
updates; no linked-list implementation was made.

The five-loop full-effect comparison remains 205.9 ms Odin versus 154.5 ms
ASM per five runs, averaged over 35 effects. See
[five-loop benchmark](five-loop-benchmark.md). The largest absolute per-effect
gaps include Scattered (29.1 ms), Swarm (24.6), Unstable (23.2), Spotlights
(23.0), Spray (21.7), Middleout (21.4), and Binarypath (21.0). These durations
can include differing animation workloads between implementations.

## Phase evidence

Diagnostic mean milliseconds per complete effect, two samples:

| Effect | Build | Effect update | Compose | Patch cells | Write |
| --- | ---: | ---: | ---: | ---: | ---: |
| Scattered | 1.14 | 30.11 | 13.05 | 9.51 | 0.31 |
| Swarm | 6.76 | 60.55 | 33.88 | 20.58 | 2.69 |
| Unstable | 1.02 | 30.20 | 15.82 | 11.55 | 0.35 |
| Spotlights | 0.92 | 40.90 | 1.52 | 6.32 | 0.45 |
| Spray | 0.95 | 33.91 | 6.51 | 8.52 | 0.92 |
| Middleout | 0.67 | 10.09 | 17.80 | 0.90 | 0.07 |
| Binarypath | 3.42 | 64.83 | 95.43 | 44.21 | 1.56 |
| Bubbles | 1.60 | 32.64 | 11.82 | 18.78 | 5.29 |
| Beams | 6.71 | 14.26 | 1.56 | 7.73 | 0.64 |

These are instrumented diagnostics, not production benchmark times.
The existing stats hook also scans emitted rows to count cells; that extra
work appears in the TSV's `diagnostic_other_ms`, and particularly inflates
high-frame-count effects. Per-frame timer/counter overhead also affects the
named phases. Update includes setters and queue gathering called by the
effect, not just mathematical functions. Use production profiles to corroborate
the direction, not these phase totals to claim a speedup.

[All phase data, including Laseretch control](effect-update-profile.tsv).

## Concrete effect-side work

**Spotlights is the clearest first target.** `spotlights_next` walks every
character and calculates a distance to every spotlight on every frame. It
then fetches and submits appearances even when the character remains dark or
fully bright. Falloff calls `adjust_color_brightness`, repeatedly converting
the same base RGB colors to HSL and back. Production samples attributed
64.89% of user cycles to `effects::next_frame` and another 17.92% to
`engine::adjust_color_brightness` (disjoint self-symbol costs).

Its ASM counterpart specifically avoids repeated illumination work when
integer spotlight positions/range/phase are unchanged, tracks the lit set,
uses distance checks/memoization, and caches adjusted visuals. Those are
algorithmic effect-side differences, not merely assembly instruction speed.
Small candidates for Odin are skipping unchanged illumination states and
comparing squared distances before calculating a square root for falloff.
A lit-set update is a larger, separate experiment; no large cache is proposed
as a prerequisite.

**Unstable repeats completed work.** Explosion and reassembly clamp progress
to 1 and still evaluate movement/setters after each particle has arrived.
Rumble recalculates gradients every frame although the color step changes
every ten frames; reassembly does so although the step changes every three.
It also rescans initial appearances every reassembly frame to decide the
phase duration. The Python reference removes settled motion from active work
while allowing unfinished color animation to continue. Candidate fixes must
preserve the arrival tick, rumble RNG, dynamic-color restoration at tick 39,
and phase/hold lengths. Approximately 51% of production user-cycle samples
are in `next_frame`, easing, and `exp2` combined, before other update callees.

**Scattered already skips settled particles**, but still computes easing and
gradient selection per active particle. Repeated `(tick, duration, easing)`
values and discrete color steps offer shared computation opportunities.
That needs bounded batching or shared data, not a new generic animation
interpreter or one private cached animation per particle.

**Swarm already uses a bounded frame batch.** Its update path still scans
active particles, copies each sample into a staging frame array, then walks
that staging array again in the bulk setter. Batch replenishment also spends
time evaluating actions and easing. Production self-symbol samples include
27.74% in `next_frame` and 7.57% in `sequence_batch`, with additional easing
and math-library work. Profile the generation/load split before adding more
batch machinery; the current batch is not free.

Middleout and Binarypath retain large composition costs. Effect-side work
does not explain the entire aggregate gap, and the renderer remains a valid
later target. A linked list specifically targets membership maintenance;
it cannot remove Spotlights' full-character illumination scan.

## Reproduction and artifacts

Production builds: `-o:speed -microarch:native -debug`; CPU 2; terminal 200x50;
input 190x46; seed 1; frame rate zero; stdout `/dev/null`.
`perf record -e cycles:u -F 999 --call-graph dwarf,8192` records repeated
complete production CLI runs, including setup. Ten effects were profiled,
with roughly 2–3 seconds of user samples per effect. Profiles contain no
lost samples; user-cycle sampling excludes kernel execution. No compilation
ran concurrently with recording. Symbol self costs are distinct from
inclusive call-stack costs and must not be added to their parents.

`/tmp/otfx-flat-profile-20260926/` retains `otfx`, `profile.sh`, per-effect
`.data`, `*-self.txt` and `*-inclusive.txt`, and `phases.tsv`. The isolated
phase harness extends `bench/phases` only with the selected effects and a
build timer. It uses the existing `OTFX_FRAME_STATS` hook, including its
known diagnostic row-scan overhead. No production instrumentation was added.
