# Setter guard experiments

Baseline: dirty-row checkpoint `863ec0ce`. All Odin binaries use
`-o:speed -microarch:native -debug`. Experiments were built in isolated copies;
the selected implementation keeps equality guards, reads the requested visual
field directly, and uses `e.particles[id].visual_id` for individual accesses.
Odin's `#soa` storage remains unchanged.

## Variants and full-effect results

1. Baseline: component setters compare through `get_visual` and skip equal
   values; prepared, whole-visual, and placement setters also skip equal values.
2. Direct fields: component setters read only the requested visual field and
   retain their equality guards. Other behavior is unchanged.
3. Unconditional: remove equality guards from symbol, foreground, background,
   bold, prepared visual, coordinate, visibility, and layer setters. Whole-visual
   assignment always rebuilds all packet fields. Optional-argument presence
   checks and shared-to-private visual ownership remain intact.
4. Particle indexing: direct fields plus `e.particles[id].field` throughout the
   visual and placement APIs, instead of `e.particles.field[id]`.

The CLI workload uses dense 190x46 input on a 200x50 canvas, seed 1, frame rate
0, stdout `/dev/null`, CPU 2 affinity, three samples, and a 0.3-second minimum
sample. Comparisons run serially; no other builds or measured workloads overlap.

| Experiment | Effects | Baseline mean best ms | Candidate mean best ms | Geometric speedup |
| --- | ---: | ---: | ---: | ---: |
| Unconditional updates | 35 | 103.6 | 129.4 | 0.795x |
| Direct fields | 8 | 164.9 | 162.1 | 1.01x |
| Direct fields + particle indexing | 35 | 103.5 | 103.3 | 1.001x |

Unconditional updates are about 26% slower by geometric mean. Direct reads and
particle indexing are effectively neutral for whole effects, and are retained
as an API implementation cleanup. This is not the requested 50% reduction.
Frame counts match in every comparison. The two 35-effect comparisons have
their own interleaved baseline measurements; the eight-effect aggregate is a
different population and cannot be compared directly to the 35-effect means.
[Per-effect results](setter-guard-benchmark.tsv) record the paired measurements.

## All-setter microbenchmarks

Each case performs 4,000 passes over 256 particles (1,024,000 calls), best of
five timed samples, on CPU 2. Repeated cases use one value; changing cases
alternate two values for each particle on successive passes. These measure
setter work without rendering, so they exclude additional row emission caused
by unconditional updates. All nine setter cases are measured in all variants.
Times below are nanoseconds per call.

| Setter | Guarded repeated | Unconditional repeated | Guarded changing | Unconditional changing |
| --- | ---: | ---: | ---: | ---: |
| Symbol | 1.836 | 4.129 | 5.670 | 4.413 |
| Foreground | 1.004 | 8.621 | 10.481 | 8.983 |
| Background | 1.005 | 8.725 | 10.844 | 8.986 |
| Bold | 0.787 | 2.691 | 2.935 | 2.601 |
| Prepared visual | 0.415 | 1.609 | 1.219 | 1.618 |
| Whole visual | 2.356 | 11.241 | 13.261 | 11.199 |
| Coordinate | 0.462 | 1.805 | 1.757 | 1.800 |
| Visibility | 0.460 | 1.061 | 1.015 | 1.029 |
| Layer | 0.373 | 0.880 | 0.814 | 0.869 |

Direct-field foreground/background changing cases measure 9.093/9.266 ns,
versus 10.481/10.844 ns through `get_visual`. Individual getter calls already
inline: this is a code-generation difference, not function-call overhead.
Disassembly shows field loads for particle-index syntax, without materializing
a whole particle. Microbenchmarks are synthetic; the whole-effect results are
the basis for keeping the guards. [All four variants](setter-microbenchmark.tsv)
are recorded separately.

## Branch counters and validation

Three independent Decrypt runs under `perf stat`, reopening input each time:

| Metric | Guarded | Unconditional |
| --- | ---: | ---: |
| User instructions | 3.238 billion | 4.138 billion |
| User branches | 806.8 million | 973.8 million |
| User branch misses | 1.210 million | 1.154 million |
| Wall time | 104.6 ms | 149.2 ms |

Branch misses decrease slightly, but instruction count increases about 28% and
runtime about 43%. The extra updates and downstream rendering outweigh the
removed guard branches in this workload. These are whole-program user-space
counters, not isolated measurements of a particular branch.

The retained implementation passes all 44 tests. Both the retained and rejected
unconditional variants match all 222 terminal-state captures against baseline
(37 effects, six fixtures). Unconditional output is allowed to contain redundant
row updates, so terminal state rather than byte identity is compared.
Sources, binaries, benchmark harnesses, disassembly, counters, and logs remain
under `/tmp/otfx-setters-20260925`.
