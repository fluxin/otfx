# Performance audit after scoped bounds checks

2026-09-26. User-cycle profiles of all 35 finite effects, using the integrated
scoped-check build before the later [32-bit ID change](u32-particles.md).
This audit itself adds no further production changes.
The accepted scoped changes are documented in [local-checks.md](local-checks.md).

## Comparison and interpretation

Current Odin mean best wall is **34.497 ms**; the previously recorded ASM
`c2be6411` mean is **30.763 ms**. Matching that reference requires **3.734 ms
off the mean, or 10.82% less time**. These are complete CLI lifecycles, including
construction. ASM was not rerun here. Effect frame counts can differ; this is
not an equal-work renderer-only comparison.

[All 35 timings and frame counts](scoped-asm-comparison.tsv) are sorted by
absolute excess time. Scattered, Middleout, and Decrypt account for 1.563 ms
of the mean gap; the first seven account for 2.826 ms. This is attribution of
the timing difference, not proof that those amounts are removable. Existing
leads on Binarypath, Rings, Laseretch, Errorcorrect, and Burn also contribute
to the aggregate and must be preserved.

## Shared work worth isolated controls

### 1. Output initializes unused descriptors every frame

The audited `src/engine/output.odin:115` declared `storage: [1024]linux.IO_Vec` without
undefined initialization. Disassembly confirms a `memset` of `0x3ff0`
(16,368) bytes on each frame; the compiler excludes the first descriptor,
which is immediately overwritten. `addr2line` resolves the call to that line.
The neighboring cursor buffer already uses `= ---`.

Every descriptor passed through `storage[:count]` is explicitly assigned,
including after a full-buffer flush. The isolated `= ---` change now removes
this clear: 35-effect mean best wall 34.674 → 34.363 ms (0.90% lower), with
586 exact captures including frames crossing the 1024-descriptor boundary.
Partial writes were not deliberately forced; retry logic is unchanged.
See [validation and full results](output-descriptors.md).

### 2. Fixed-size dirty iteration still uses a general iterator

Exclusive `bit_array.iterate_by_set` samples: Print 13.17%, Rain 9.84%,
Colorshift 9.40%, Bouncyballs 8.97%, Bubbles 8.05%, Laseretch 6.62%.
These samples include cell and/or row iteration; they are not solely cell
iteration. The library reloads the word and handles bias, length, and bit
position for each returned bit. Engine dimensions and zero bias are fixed
during playback.

Completed: call-site inlining alone left the private native helper as a call
and measured 1.18% slower. A small private inline traversal using the native
iterator state removed those render/output calls and reduced the 35-effect
mean best wall from 34.400 to 33.429 ms (2.82%). Storage and effect APIs stay
unchanged. [Experiments and validation](inline-dirty-iteration.md).

Spotlights also retains three generic `bit_array.set` call sites over a
pre-sized zero-bias candidate array. Set itself receives 7.91% inline samples,
with another 2.08% attributed to its resize helper. Those indices come from
valid character spans or the previously lit set. This is a small local follow-up
to the already successful engine write change, rather than a global solution.

### 3. Unchanged samples still reach setters

Completed for Wipe, Highlight, Decrypt, and Scattered. See the
[isolated and combined measurements](held-publishing-and-bulk-fill.md).
The following profile observations motivated those changes; other named
effects remain follow-ups.

Wipe holds each frame for three ticks but calls `set_symbol` and
`set_appearance` each tick. Its default 13-frame timeline therefore performs
39 publication attempts per particle. Symbols remain the same throughout.
Decrypt's fast phase repeats each symbol for two ticks; discovered colors are
held for five. Highlight repeats its palette entries for two ticks. Scattered
recomputes a discrete color step while that step is unchanged.

Sampled comparisons reflect this: Wipe has 9.95% in appearance equality and
7.31% in `set_symbol`; Fireworks has 5.17% in appearance equality; Slice has
12.60% in equality work. These are inline-attributed instruction samples, not
necessarily out-of-line `memcmp` calls.

Keep setter guards. Avoid entering setters when the effect already knows the
sample is held. `sample_timeline_changes` already serves Smoke and Decrypt's
typing phase. Reuse that contract where it fits; a simple tick-boundary branch
may be sufficient elsewhere. Preserve re-entry, other writers, final publication,
and completion ticks. No generic event scheduler or complete-animation cache
is needed. Prior Beams due-time buckets regressed and are not recommended again.

### 4. Packet and appearance resolution are shared costs

Packet-copy inline samples include Wipe 25.45%, Spotlights 12.49%, Decrypt
6.36%, and Swarm 3.49%. Appearance resolution receives 19.64% in Colorshift,
12.65% in Waves, and 8.86% in Decrypt. These are evidence that the shared
publication path matters; they do not isolate cache misses from instructions
or prove that full `Appearance` values are copied by every getter.

Do not repeat rejected prefix-splitting or prepared-gradient changes. First
reduce unnecessary publication upstream. Any next packet experiment must
retain one fixed-slot representation and be isolated from effect changes.
Splitting glyph/style dirty state could reduce writes, but requires additional
state and invalidation rules; it is not the first simplification to pursue.

### 5. Cell stacks pay for singleton storage and crowded searches

Every occupied cell currently appends its first key to an initially empty
dynamic stack, even though `Render_Cell.top` already records the winner.
Highlight has 48.63% of samples on the append-to-cell-stack allocation path.
These are arena allocator operations, not necessarily one OS allocation per
cell. The shared issue is per-cell dynamic-array construction.

An isolated singleton representation using the existing top field, allocating
an ordered stack only on collision, is a candidate. It adds a storage case and
must justify that complexity. Preserve ordered removal, painter order, and
hidden-particle departure; do not silently replace the ordered stack contract.

Middleout is a different stack cost: 38.44% of samples are in binary search
(20.57% removing, 17.86% inserting), with another 3.48% in dynamic-array resize
under insertion. Effect dispatch/update is only 7.39% self. Shared axis-motion
calculation is already present. Changing easing or sorting the whole stack again
does not address this measurement. Search count/comparator codegen can be
screened separately before adding persistent slot bookkeeping.

### 6. Build-time timeline filling is still element-at-a-time

Completed for the shared constructors and Sweep's directly built timelines;
[bulk-fill results](held-publishing-and-bulk-fill.md). Existing API retained.

Wipe has 26.64% self samples in `append_soa_elem(Frame)` called from
`create_gradient_timeline`. The default dense input builds 13 frames for each
input particle. Capacity is reserved, but every append still performs the
generic SoA operation and writes a whole frame value.

`create_hold_timeline` and `create_gradient_timeline` can be screened with one
resize and direct filling of the resulting SoA span, retaining their existing
API. Wipe and Sweep are the only current `Frame_Timeline` effect consumers;
this is a shared primitive improvement with a bounded consumer set, not an
all-35 engine win. Do not replace the SoA representation based on this finding.

## Effect-specific costs that remain

- Scattered: easing function 8.05% self plus roughly 9% in prominent libm
  samples; queueing and interpolation also remain. Particles with identical
  duration/easing at a tick could share the factor, but that is an effect-level
  screen, not proof that all motion should be precomputed.
- Swarm: sequence generation 8.42% self, frame publication 6.11% inline,
  plus easing/libm and composition. Existing batch generation does not remove
  frame publication or membership maintenance.
- Fireworks: effect update caller 55.62% self, including easing, interpolation,
  comparisons, and placement publication; `exp2` adds 6.02% self.
- Spotlights: brightness conversion 20.58% self, square roots 8.40% inline,
  plus candidate marking. Cached immutable color-space inputs and comparing
  squared distances before a needed square root are candidates, with color
  semantics and rounding validated separately.
- Blackhole: effect update 50.81% self includes repeated publication and
  gradient work; renderer/lifecycle caller is 36.72% self. The source already
  shares some easing factors by duration, so avoid proposing that as new work.

## Recommended order

1. Output descriptor initialization: smallest shared control, no API change.
2. Native bit iterator inlining and remaining fixed-size Spotlight writes,
   measured independently.
3. Shared timeline bulk fill, then held-sample publication screens per effect.
4. Singleton stack storage and Middleout search costs as separate renderer
   experiments; preserve the current ordered implementation as reference.

No individual control has a promised gain. Sampled percentages overlap when
inline children and parents are both shown; do not add them or apply one
effect's share to the whole suite. Global wins must pass the full 35-effect
benchmark and capture matrix, while preserving existing faster-than-ASM cases.

## Evidence and reproduction

Binary: `/tmp/otfx-local-checks-20260926/integrated`, SHA-256
`8efb953ab62d76ab1066c4c2470940c21e1d73a2058a3d9ee771114636742d59`.
Flags `-o:speed -microarch:native -debug`; assertions enabled. CPU 2,
terminal 200x50, input 190x46, seed 1, frame rate zero, output `/dev/null`.
Each profile repeats full CLI invocations, including build/playback/cleanup.
The first seven effects use about three seconds of baseline work each; the
remaining 28 use about two seconds each, with exact repetition counts saved.

`perf record -e cycles:u -F 999 --call-graph dwarf,8192`; all 35 recordings
report zero lost samples. No builds, tests, or throughput benchmarks ran during
profiling. These are user-cycle profiles, not kernel/output-emulator timings
or fresh throughput measurements. Short-effect samples are about 1K; larger
ones about 2-3K. Fine differences deserve controlled timing, not inference from
one sample screen.

[Exclusive symbol samples at or above 1%](scoped-perf.tsv) preserve the full
35-effect symbol view. Inline attribution and complete call chains are in
`/tmp/otfx-scoped-offenders-20260926/*-self.txt`; raw recordings, `profile.sh`,
`profile-remaining.sh`, `remaining.tsv`, and `run-effect.asm` are beside them.

## Full timing chart

Milliseconds per complete animation; positive delta means Odin is slower.
Frame counts and ratios are retained in the linked TSV.

| Effect | Scoped Odin | Recorded ASM | Delta |
| --- | ---: | ---: | ---: |
| scattered | 48.7 | 24.8 | +23.9 |
| middleout | 26.2 | 8.4 | +17.8 |
| decrypt | 29.9 | 16.9 | +13.0 |
| swarm | 106.8 | 95.4 | +11.4 |
| fireworks | 73.6 | 62.5 | +11.1 |
| spotlights | 37.6 | 26.6 | +11.0 |
| blackhole | 65.6 | 54.9 | +10.7 |
| slide | 21.6 | 12.7 | +8.9 |
| bouncyballs | 38.2 | 29.6 | +8.6 |
| waves | 24.1 | 15.7 | +8.4 |
| expand | 24.8 | 16.6 | +8.2 |
| unstable | 42.9 | 35.3 | +7.6 |
| vhstape | 30.9 | 24.3 | +6.6 |
| orbittingvolley | 23.8 | 17.4 | +6.4 |
| synthgrid | 11.1 | 5.1 | +6.0 |
| bubbles | 51.4 | 46.6 | +4.8 |
| colorshift | 21.9 | 17.1 | +4.8 |
| smoke | 14.1 | 9.6 | +4.5 |
| slice | 10.7 | 6.6 | +4.1 |
| beams | 14.8 | 11.6 | +3.2 |
| pour | 20.1 | 16.9 | +3.2 |
| wipe | 5.2 | 2.8 | +2.4 |
| sweep | 6.2 | 4.2 | +2.0 |
| print | 8.1 | 6.7 | +1.4 |
| randomsequence | 4.7 | 3.7 | +1.0 |
| highlight | 3.7 | 2.8 | +0.9 |
| rain | 19.1 | 19.2 | -0.1 |
| overflow | 11.7 | 12.2 | -0.5 |
| crumble | 47.2 | 49.0 | -1.8 |
| spray | 25.0 | 26.9 | -1.9 |
| burn | 22.7 | 25.6 | -2.9 |
| errorcorrect | 13.6 | 22.3 | -8.7 |
| laseretch | 47.8 | 59.3 | -11.5 |
| rings | 88.7 | 104.0 | -15.3 |
| binarypath | 164.9 | 183.4 | -18.5 |
| **Mean** | **34.497** | **30.763** | **+3.734** |
