# Current renderer CPU profile

Profiled the `b0cb53df` renderer plus the two exact-size color stores retained
from the row-slot experiment. Native Odin build uses
`-o:speed -microarch:native -debug`, with bounds checks retained. Workload is
dense 190x46 input on a 200x50 canvas, seed 1, unpaced `/dev/null` output,
affinity CPU 2. `perf record` samples `cycles:u` at 997 Hz with 16 KiB DWARF
stacks. Colorshift runs 100 times, Binarypath and Laseretch 10 times, Burn 20
times. Each effect records approximately 2,000-4,000 samples, with none lost.
Build/startup work is included.

Percentages below aggregate self samples by attributed source line, not
inclusive call-tree percentages. Optimized/inlined source attribution is
approximate. Generic runtime checks and shared builtins cannot all be assigned
to their calling stage and remain separate. These are user CPU samples;
`writev`'s kernel work and terminal parsing are not represented.

| Source region | Colorshift | Binarypath | Burn | Laseretch |
| --- | ---: | ---: | ---: | ---: |
| Candidate membership passes | 15.5% | 23.5% | 12.8% | 17.3% |
| Clearing, clipping, placing cells | 19.8% | 25.4% | 25.6% | 33.8% |
| Row traversal and output slices | 8.0% | 8.5% | 11.8% | 14.2% |
| Userspace writev handling | 3.5% | 1.0% | 6.1% | 4.6% |
| RGB/SGR encoding (`packet_color`) | 0.5% | 0.1% | 0.8% | 0.5% |
| Runtime checks | 12.6% | 8.6% | 9.4% | 8.4% |

The remainder is effect logic, dirty marking, allocation/build work, and other
shared code. RGB encoding is a small target in these workloads: most common
palette updates select prepared appearances. RGB SoA may help a workload that
computes many new colors, but it would not address this profile's dominant
renderer scans.

Laseretch's largest individual attributed lines are viewport clipping at
`render.odin:46` (16.81%) and the pending-selection check at `render.odin:34`
(12.03%). Clearing/clipping/placement plus membership bookkeeping account for
roughly half its sampled user cycles. Particle storage is already `#soa`;
`current_coord` remains a column of coordinate pairs. Useful next experiments
are batched viewport tests and reducing repeated membership passes, with
collision ordering and changing candidate slices preserved.

Raw profiles, commands, reports, and aggregation script:
`/tmp/otfx-color-store-20260925/profile`.
[Aggregated measurements](renderer-profile.tsv).
