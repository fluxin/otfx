# Group construction, prefix copying, and due-time experiments

2026-09-26. Four independent variants were compared with the same frozen
pre-experiment source, after reverting the prepared-gradient experiment with
user approval. **Only radix ordering is integrated.** Nothing was committed;
the other variants and all earlier WIP remain preserved.

## Result

Native optimized/debug builds, `-o:speed -microarch:native -debug`, CPU 2,
terminal 200x50, input 190x46, seed 1, frame rate 0, stdout `/dev/null`.
Measurements include build and playback. Each sample batches children for at
least 0.5 seconds. Two samples per grouping/renderer variant; three for due-time
buckets. No concurrent compilation, tests, or profiles during timing.

| Independent variant | Beams before → after | 35-effect mean best wall before → after | Geometric speedup |
| --- | ---: | ---: | ---: |
| Counting + flat spans | 23.5 → 16.8 ms | 39.377 → 38.260 ms | 1.0717x |
| Radix + flat spans | 23.6 → 17.2 ms | 38.711 → 37.640 ms | 1.0708x |
| Encode first, copy second | 24.0 → 25.9 ms | 38.271 → 41.660 ms | 0.9185x |
| Beams due-time buckets | 22.0 → 22.9 ms | Not rerun: effect-local change | 0.9607x for Beams |

Each row has its own paired baseline measurement. Host timing drift means the
after columns alone cannot rank variants across runs. Counting and radix each
reduce their paired arithmetic mean by approximately 2.8%; geometric speedup
weights relative changes rather than milliseconds saved.

The targeted head-to-head uses **counting as reference, radix as candidate**:

| Effect | Counting | Radix |
| --- | ---: | ---: |
| Beams | 16.0 ms | 16.0 ms |
| Decrypt | 32.5 ms | 32.2 ms |
| Middleout | 26.5 ms | 26.6 ms |
| Fireworks | 75.8 ms | 75.7 ms |

The initial counting Middleout regression (26.9 → 27.9 ms) did not repeat
(26.7 → 26.6 ms). The initial radix Decrypt regression (32.6 → 38.6 ms) also did
not repeat (32.6 → 32.1 ms). The raw full-suite table retains those original
measurements instead of silently replacing them with rechecks.

Mean child CPU: counting 39.666 → 38.254 ms; radix 38.720 → 37.743 ms;
split 38.249 → 41.566 ms. Mean peak RSS: counting 12,770 → 13,265 KiB;
radix 12,782 → 13,129 KiB; split 12,785 → 12,786 KiB. Due-time Beams CPU
21.9 → 22.9 ms, peak RSS 14,044 → 14,188 KiB. Frame counts match in every pair.

[All per-effect wall, CPU, RSS, and frame measurements](grouping-experiments.tsv).
ASM was not rebuilt, fetched, or rerun. These are Odin-versus-frozen-Odin pairs;
the harness labels the frozen baseline `rust`.

## API and selected implementation

Effect-facing APIs remain unchanged:

```odin
groups := engine.get_particles_grouped(query, filter, .Row_B2T)
for i in 0 ..< len(groups.spans) {
    members := engine.group_members(groups, i)
    // Build this effect's state from members.
}
engine.groups_delete(&groups)
```

`Particle_Query` supplies particle sets, initial-coordinate slices, and canvas
metadata. `Particle_Groups` owns one flat member pool and spans; `group_members`
borrows a slice. Effects do not select algorithms, reserve bucket storage, pack
keys, or retain sorting scratch. Both `get_particles` and `get_particles_grouped`
use the same private ordering helper, so future effects inherit the improvement.
The public group-direction and within-group coordinate ordering stay unchanged.

The counting version stably distributes records by within-group key and then
group key. Histogram ranges are bounded relative to particle count; sparse
coordinate ranges fall back to the original comparison sort. Resulting ordered
records are emitted into the existing flat pool/spans representation.

The selected radix version stably sorts normalized integer keys in byte passes,
within-group first and group second. It skips constant high bytes, retains
machine-sized keys, and handles negative/reversed group keys without narrowing.
Scratch consists of one input-sized record slice and a 256-counter histogram;
no coordinate-sized allocation or sparse-layout fallback is needed. It adds
38 net production lines versus the baseline; counting adds 47. Neither uses a
second canvas or persistent ordering cache.

Radix was selected because the head-to-head is effectively tied, while radix
has fewer lines and a single bounded-memory ordering path. Modified production
file: `src/engine/group.odin`. Added test: `tests/group_order.odin`.

## Other variants remain isolated

**Encode/copy split:** a first pass over dirty cells resolves winning appearances
and encodes dirty prefixes. The existing patch pass then copies prefixes into
the canvas. No queue or temporary packet buffer was added. The extra traversal
and repeated appearance resolution lost approximately 8.9% aggregate wall time.
This is a failed scheduling experiment, not evidence that every possible packet
encoding change must lose. No renderer changes were integrated.

**Due-time buckets:** Beams keeps one cancellable appointment per particle in
64 rotating buckets. Particle-indexed previous/next links support constant-time
restart cancellation without stale duplicate entries or playback allocations.
Normal holds visit only the due bucket; holds longer than 64 ticks are checked
on bucket wraps. Storage is independent of hold duration. The prior flat active
list costs 8 bytes per member; appointments cost 24 bytes per indexed particle
plus 512 bytes of bucket heads. Fade arithmetic, RNG, phase gates, and final
holds remain unchanged. Default Beams was 4.1% slower, so this scheduling code
was not integrated or generalized into an engine API.

## Validation and artifacts

- All variants: formatting, `odin check`, native optimized/debug build.
- Counting/radix: 80 tests, 76 pass; split: 79 tests, 75 pass; due: 80 tests,
  76 pass. The same four existing allocation tests fail in every variant.
- Group-order test compares all ten directions with comparison-sort results,
  including shuffled input/fill sets, empty selections, and sparse coordinates.
- Counting, radix, split: each passes 222 standard + 354 edge captures, all exact.
- Due: 222 standard + 144 Beams captures, all exact, including same-tick restarts,
  color modes, and 64/65/129-tick holds. Its added cancellation/wrap test passes.
- Every variant: 37 smoke checks; parity 13 matches, 24 existing diagnostic
  differences, zero failures. Matrix/Thunderstorm are validated but excluded
  from the 35 finite-effect throughput means.
- Integrated source matches the validated radix source; final check/build and
  tests pass with the same four known test failures. Root `./otfx` unchanged.

Artifacts: `/tmp/otfx-grouping-experiments-20260926/`, with independent
`baseline`, `counting`, `radix`, `split`, and `due` source trees/binaries,
validation logs, scripts, captures, `binaries.sha256`, and `head-to-head.log`.
Each variant's `screen.log`, `bench-rest.log`, and `results.tsv` retain raw paired
measurements; grouping `recheck.log` files retain regression checks.
`bench.sh` records exact full-suite invocations. No experiment source was deleted.
