# Five complete effect loops in one process

Historical baseline before the [active-work effect changes](effect-active-work.md).
Those newer changes have targeted measurements, not a refreshed five-loop aggregate.

Measured 2026-09-26. Each of the 35 finite effects runs five complete
build/playback lifecycles inside one executable invocation, with seed 1 reset
before each loop. This is not five separate process launches and does not
replay cached output or reuse a completed effect's state.

Three frozen versions were measured: the flat sorted stack, the current
append-and-sort experiment, and the latest fetched ASM revision `c2be6411`.
Only isolated benchmark copies of their main loops were modified. Production
sources and the root executable were not changed for this measurement.
Bulk-sort was subsequently removed with user approval. Nothing committed.

## Results

Arithmetic means across 35 effects:

| Metric | Flat stack | Bulk sort | ASM |
| --- | ---: | ---: | ---: |
| Whole-process wall, five loops | 205.89 ms | 210.11 ms | 154.51 ms |
| Whole-process wall divided by five | 41.18 ms | 42.02 ms | 30.90 ms |
| Whole-process child CPU, five loops | 205.11 ms | 209.34 ms | 153.83 ms |
| Mean process high-water RSS | 12.22 MiB | 12.23 MiB | 48.85 MiB |
| Resident RSS after loop 1 | 6.90 MiB | 6.89 MiB | 48.85 MiB |
| Resident RSS after loops 2 through 5 | 8.25 MiB | 8.24 MiB | 48.85 MiB |

Flat-stack Odin takes 33.3% more whole-process time than ASM; matching ASM
requires approximately a 25% reduction from current flat-stack time.
Bulk-sort takes 2.0% more time than the flat stack. These are full effect
durations; the implementations do not necessarily produce identical numbers
of animation frames. This experiment does not establish cross-engine parity.

Internal loop timers exclude CLI startup and memory-reporting overhead but
include the lifecycle described below:

| Loop | Flat stack ms | Bulk sort ms | ASM ms |
| --- | ---: | ---: | ---: |
| 1 | 41.44 | 42.07 | 30.75 |
| 2 | 40.91 | 41.68 | 30.70 |
| 3 | 40.81 | 41.60 | 30.61 |
| 4 | 40.81 | 41.98 | 30.51 |
| 5 | 40.84 | 41.69 | 30.51 |

All 35 effects in all three variants have exactly unchanged end-of-loop RSS
from loop 2 through loop 5. That establishes bounded memory for this five-loop
screen, not a general leak proof. Odin's increase between loops 1 and 2 can
reflect retained arena blocks and allocator caching. Binarypath, for example,
settles at 19,804 KiB after loop 2 rather than continuing to grow.

Bulk-sort whole-process regressions above 2% in this screen: Blackhole +20.2%,
Crumble +4.9%, Expand +9.9%, Orbittingvolley +2.4%, Print +5.1%, Slice +2.9%,
Swarm +2.9%, Vhstape +11.5%, Wipe +2.2%. Middleout improves only 1.6%.
This is one five-loop process per effect/version, not five independent trials;
small differences are not established as statistically significant.

## Lifetime and measurement boundaries

Odin uses its existing `run_effect_once` and a single `Dynamic_Arena`.
After each completed run, arena reset retains normal blocks for reuse and
frees out-of-band allocations. The final arena is destroyed on process exit.
Effect and renderer state are rebuilt each loop; the frame loop and its
temporary-allocator reset are unchanged.

ASM uses its existing `try_run`. Its native entry point releases the previous
run's regions and zeroes run state before building the next effect. It retains
the final regions until process exit, matching its existing lifecycle. No new
ASM cleanup policy was introduced. Forced ASM tier 4 prevents silent fallback.

RSS is read from `/proc/self/status` after each completed loop: `VmRSS` for
resident memory and `VmHWM` for process high-water memory. The peak in the
comparison table is the maximum reported `VmHWM` through all five loops,
not an average of current RSS and not multiplied by five. The raw `wait4`
peak is also retained in `five-loop-raw.tsv`; it has a roughly 19 MiB launcher
floor on this setup and is therefore not used for the RSS comparison.
Whole-process CPU uses `wait4` user+system time, and whole-process wall includes
launch, all five loops, telemetry, and final exit.

Both Odin variants use `-o:speed -microarch:native -debug`; ASM is an offline
release rebuild of the cached source with only its main-loop driver changed.
Terminal 200x50, input 190x46, frame rate zero, stdout `/dev/null`, CPU 2.
Variant order rotates across effects. No builds or captures ran concurrently
with timing. Matrix and Thunderstorm are excluded because their default
wall-clock duration is not finite-effect throughput.

## Validation and artifacts

105/105 comparisons pass: each modified binary's five-loop output is exactly
five copies of its original binary's single-run output, for all 35 effects.
These captures use a small fixed input, 40x12 canvas, and virtual time.
All five loops are also confirmed by telemetry in the full-size timed runs.
The existing four allocation-test failures in production are not addressed.

- [Per-effect comparison](five-loop-comparison.tsv)
- [Raw timings and per-loop memory](five-loop-raw.tsv)
- `/tmp/otfx-five-loops-20260926/`: source copies, binaries, build log,
  `prepare.py`, `run.py`, `summarize.py`, capture checks, and individual logs.

Re-run the frozen comparison from the repository root:

```sh
UV_CACHE_DIR=/tmp/uv-cache uv run python /tmp/otfx-five-loops-20260926/run.py
UV_CACHE_DIR=/tmp/uv-cache uv run python /tmp/otfx-five-loops-20260926/summarize.py
```
