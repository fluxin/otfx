# Viewport SIMD experiment

Keep the existing engine clipping loop. Explicit four/eight-particle batches
regress the representative effect screen; the small unsigned alternatives are
neutral or slightly slower. No extra coordinate arrays, raw pointers, staged
renderer buffers, or batch APIs are retained.

The baseline at `ae5368b2` already emits SIMD for each coordinate pair. Native
assembly for `compose_frame`, inlined into `main::run_effect_once`, includes
`vpaddq`, two `vpcmpgtq` comparisons, and mask-combining instructions for the
four viewport bounds. The source expression is scalar, but the machine code
is not. Profiling a source line as hot does not mean that line lacks SIMD.

## Variants and results

All use `-o:speed -microarch:native -debug`, retaining runtime bounds checks.
The paired CLI screen uses dense 190x46 input on a 200x50 canvas, seed 1,
CPU 2, unpaced `/dev/null` output, three samples with a 0.3-second minimum.
Each variant is compared with the unchanged `ae5368b2` binary in its own run.
The benchmark's historical `rust` label denotes the old Odin renderer.

| Variant | Description | Geometric speedup | Mean best ms, baseline / candidate |
| --- | --- | ---: | ---: |
| Eight particles | Gather coordinates, wide viewport comparisons, iterate surviving lanes | 0.86x | 163.6 / 189.7 |
| Four particles | Filter invisible particles early, reuse gathered coordinates | 0.81x | 162.6 / 196.4 |
| Unsigned scalar | One unsigned interval comparison per axis | 1.00x | 162.7 / 162.5 |
| Unsigned vector pair | One unsigned two-axis vector comparison | 0.97x | 163.4 / 168.1 |

[Per-effect measurements](wide-clipping-benchmark.tsv). Frame counts match
for every comparison. This is an eight-effect rejection screen, not a claim
that all SIMD formulations or a different coordinate layout would lose.

The explicit batch forms load/gather positions into vectors and then iterate
surviving lanes for dirty-row tests and collision placement. The initial form
also revisits coordinates and checks visibility after clipping. The second
form removes those particular costs but remains slower. Both retain scalar
collision resolution so repeated IDs and overlapping particles behave exactly
as before. The results do not establish that clipping arithmetic alone is
responsible for the measured source-line percentage.

The unsigned vector pair lowers to `vpcmpnleuq` plus `kortestb`, but fewer
comparison instructions did not produce a whole-effect speedup. Its interval
arithmetic explicitly rejects an inverted viewport before testing unsigned
distances. Signed integer extremes and translated coordinates were tested.

## Validation and remaining opportunity

- Four/eight-particle variants each pass 44 tests and 222/222 byte-exact captures.
- Both unsigned variants pass 45 tests and 222/222 byte-exact captures.
- The additional test compares signed-extreme coordinates and an empty viewport
  against the independent painter oracle. It is retained with the original loop.
- The sample uses actual effects, including selected candidate slices, all-ID
  traversal, overlapping particles, clipped particles, and tails shorter than a
  vector. A dedicated mostly-offscreen clipping workload was not measured.

The [CPU profile](renderer-profile.md) points to repeated candidate membership
passes (13-24% of sampled user cycles) and clearing/clipping/placement (20-34%)
as the larger opportunities. Particles already use SoA storage, while
`current_coord` is a column of coordinate pairs. Separate coordinate component
columns could avoid batch packing, but that storage change has not been tested;
it is not a demonstrated speedup. RGB/SGR encoding is under 1% in these profiles.

Source snapshots, binaries, assembly, tests, captures, and raw timings are under
`/tmp/otfx-wide-clip-20260926`.
