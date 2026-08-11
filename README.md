# otfx

Odin-native terminal text effects. Pipe text in, choose an effect:

```sh
ls -la | otfx decrypt
cat banner.txt | otfx beams
fortune | otfx --random-effect
git log --oneline -10 | otfx matrix
```

<img src="third_party/ttfx/docs/effects/decrypt.gif" width="588" alt="reference ttfx decrypt animation">

The animation above is the Rust `ttfx` reference render. `otfx` follows the
same effect vocabulary and CLI shape, but it is a native Odin implementation
with a deliberately different renderer and direct state machines. It does not
claim byte-for-byte terminal-stream parity.

## Why otfx

[`third_party/ttfx`](third_party/ttfx) is a Rust port of
[TerminalTextEffects](https://github.com/ChrisBuilds/terminaltexteffects).
`otfx` is a second, Odin-native implementation aimed at the same practical
job: a small shell-friendly binary that turns piped text into an animation.

The design is data-oriented from the renderer through the effects:

- `#soa[dynamic]Character` keeps the hot visibility, coordinate, painter-key,
  and visual columns contiguous.
- One engine-owned allocation holds both sides of the terminal cell buffer.
  Effects feed it; no effect owns a second canvas or raster.
- The renderer compares the current and prior cell grids and emits only changed
  terminal runs into one reusable byte buffer.
- Effects use flat `[dynamic]` pools, spans, and `Char_Groups {chars, offsets}`.
  They do not use maps for character state.
- Newer effects evaluate movement, color ramps, and phase state directly from
  dense columns rather than allocating paths, scenes, callbacks, or per-glyph
  objects.
- Geometry and interpolation use Odin's native math/linalg primitives; cyclic
  hot loops use branch wraps or precomputed lookup columns rather than `%`.

## otfx versus ttfx

| | `otfx` (Odin) | `ttfx` (Rust reference) |
|---|---|---|
| Implementation | SoA engine, direct effect phase machines, shared dirty renderer | Per-effect paths/scenes/events and full reference renderer |
| Terminal output | Dirty cell runs only | Reference terminal stream |
| Supported effects | 37 | 37 |
| CLI for shared effects | Same effect names and option names | Reference contract |
| Deterministic seed | `--seed` resets Odin's native RNG | `--seed` resets ttfx's RNG |
| Byte-stream parity | Not a goal yet | Byte-exact against Python TTE |
| Pre-existing SGR/dynamic color modes | Not at reference parity | Supported |
| Terminal resize rebuild | Settled `SIGWINCH` rebuild; inactive for redirected output | Supported |

All 37 reference command names are exposed by `otfx`, including
**`thunderstorm`**. Every implementation is Odin-native.

This is an important distinction: **effect coverage is not byte-stream
parity.** Given the same seed, the two programs may use different random draws,
frame counts, terminal bytes, and intermediate composition while still
producing the same named effect and honoring its supported option surface.

## Performance

[`bench/bench.odin`](bench/bench.odin) runs the real Rust and Odin CLIs with
the same dense 200×50 input, seed, and `--frame-rate 0`. It reports best and
mean wall time, mean child CPU time, a single exact Linux `wait4` peak-RSS
observation, and observed terminal frame markers. This is an end-to-end
production benchmark, not terminal-stream or intermediate-frame parity.

Current five-repeat results (`BENCH_MIN_SECONDS=1`) for the direct Wipe/Sweep
timelines are:

| Workload | Rust wall, best / mean | Odin wall, best / mean | Rust / Odin peak RSS | Frames | Result |
|---|---:|---:|---:|---:|---:|
| Wipe | 41.0 / 41.2 ms | 10.8 / 10.9 ms | 53.6 / 14.0 MiB | 138 / 138 | 3.80× faster; 74% lower RSS |
| Sweep | 47.9 / 48.8 ms | 18.2 / 18.2 ms | 56.8 / 15.1 MiB | 220 / 220 | 2.63× faster; 73% lower RSS |

Child CPU time is retained in the benchmark report. It is deliberately not a
headline metric for these short processes: scheduler and process-start
granularity make it less stable than elapsed wall time.

### Wall-clock-gated effects

`matrix` (`--rain-time`) and `thunderstorm` (`--storm-time`) deliberately run
for a configured interval. With pacing disabled, both use a full CPU core;
their elapsed-time ratio and emitted frames are therefore diagnostics, **not**
normalized throughput or semantic-parity claims.

The following single-run diagnostics use `BENCH_MATRIX_RAIN_TIME=1` and the
default `--storm-time 1` at 200×50. CPU is child CPU time divided by elapsed
wall time; peak RSS is one `wait4` observation. Frame counts are host- and
renderer-dependent observations only.

| Effect | Rust elapsed / CPU | Odin elapsed / CPU | Rust / Odin peak RSS | Observed frames, Rust / Odin |
|---|---:|---:|---:|---:|
| Matrix (`--rain-time 1`) | 1.132 s / 99.0% | 1.129 s / 98.3% | 45.1 / 11.0 MiB | 7,188 / 21,772 |
| Thunderstorm (`--storm-time 1`) | 1.181 s / 99.1% | 1.014 s / 98.6% | 142.8 / 11.0 MiB | 2,617 / 30,690 |

Different frame counts in the same time window are expected with the two
renderer designs. A speed or parity claim for these effects needs a shared
virtual clock and a fixed logical-frame capture harness.

Run the current production benchmark with:

```sh
odin build src -o:speed -out:otfx
BENCH_MIN_SECONDS=1 odin run bench -- 5
```

The benchmark is entirely Odin; it sets fixed terminal dimensions for each
child process, batches short effects into multi-second samples, and emits an
end-of-run summary of unweighted mean wall time, child CPU time, peak RSS, and
geometric wall-speedup. Matrix and Thunderstorm are explicitly excluded from
that normalized summary. `BENCH_MATRIX_RAIN_TIME` and `BENCH_STORM_TIME` can
shorten their default 5-second and 1-second diagnostic windows.

### Compile time

These are same-host wall times. “Cacheless” means a fresh Rust target directory
or a fresh Odin output path; it does not redownload dependencies. “Repeated”
means the immediate repeat of the same command. Rust reuses compiled artifacts;
Odin's direct build still performs its compilation work. The Rust invalidation
row is one behavior-neutral crate-local constant added after a cached release
build, so it measures a real cached source edit rather than a clean build.

| Build | ttfx Rust debug | ttfx Rust release | otfx Odin debug | otfx Odin release |
|---|---:|---:|---:|---:|
| Cacheless | 4.09 s | 19.32 s | 0.78 s | 6.11 s |
| Repeated | 0.04 s | 0.03 s | 0.77 s | 6.15 s |
| Cached source invalidation | — | 17.54 s | — | — |

The Rust debug cacheless measurement is included for fun as well as the
optimized comparison. These are compile latency samples, not a compiler quality
ranking: toolchains, CPU parallelism, cache state, and dependency graphs differ.

## Effects

`otfx` exposes the same 37 effect commands as `ttfx`:

| | | |
|---|---|---|
| beams | binarypath | blackhole |
| bouncyballs | bubbles | burn |
| colorshift | crumble | decrypt |
| errorcorrect | expand | fireworks |
| highlight | laseretch | matrix |
| middleout | orbittingvolley | overflow |
| pour | print | rain |
| randomsequence | rings | scattered |
| slice | slide | smoke |
| spotlights | spray | swarm |
| sweep | synthgrid | unstable |
| vhstape | waves | wipe |
| thunderstorm | | |

Reference animations for the corresponding ttfx effects are available under
[`third_party/ttfx/docs/effects`](third_party/ttfx/docs/effects). They document
the reference art direction, not byte-identical otfx output.

<img src="third_party/ttfx/docs/effects/fireworks.gif" width="390" alt="reference fireworks">
<img src="third_party/ttfx/docs/effects/blackhole.gif" width="390" alt="reference blackhole">

Each effect has its own options:

```sh
otfx blackhole --help
otfx matrix --help
otfx bubbles --help
```

## Usage

```text
<producer> | otfx [terminal options] <effect> [effect options]

otfx --help                 # terminal options and all exposed effects
otfx <effect> --help        # options for one effect
```

Terminal options go before the effect name; effect options go after it.

```sh
# terminal options first
printf 'hello\n' | otfx --seed 42 --frame-rate 0 --canvas-width 80 rain

# effect options after the effect
printf 'hello\n' | otfx --seed 42 bubbles --bubble-delay 1 --rainbow
```

Supported terminal options include canvas sizing/anchoring, wrapping, color
suppression, terminal background color, input-file selection, reproducible
seeds, random effect selection, and frame pacing. Run `otfx --help` for the
authoritative list.

When stdout is an interactive terminal and canvas geometry follows terminal
dimensions, a settled `SIGWINCH` ends the current run, clears its old canvas
area, and rebuilds the engine and effect against the new layout. Redirected
output and `--ignore-terminal-dimensions` deliberately do not install this
interactive behavior. `--reuse-canvas` is honored for the initial run and is
cleared on a resize because that old DEC cursor anchor has just been erased.

## Building and validation

```sh
tools/setup/download_ttfx.sh
third_party/ttfx/bin/build
odin check src
odin build src -o:speed -out:otfx
```

`third_party/` is intentionally ignored. The download script pins the Rust
reference revision used for the published comparison data, applies the tracked
compile compatibility/timing patch, and never replaces a different local
checkout.

The quick supported-effect smoke matrix is:

```sh
for effect in slide beams rings waves matrix decrypt rain wipe scattered expand \
  middleout colorshift highlight sweep randomsequence pour bouncyballs spray \
  slice overflow print errorcorrect unstable smoke burn crumble fireworks \
  spotlights vhstape orbittingvolley synthgrid bubbles binarypath swarm \
  laseretch blackhole thunderstorm
do
  printf 'hello\nworld\n' | COLUMNS=80 LINES=24 \
    ./otfx --seed 42 --frame-rate 0 --max-frames 4 "$effect" >/dev/null
done
```

This validates construction and early-frame execution for every exposed effect.
It does not replace a future parity harness with virtual time and captured
logical frames.

## Remaining parity work

Effect-command coverage and resize rebuilding are complete. The remaining work
is deliberately tracked separately from throughput claims:

- Parse and preserve input SGR state, including `--xterm-colors` and
  `--existing-color-handling=always|dynamic`; that requires source color columns
  and effect-level dynamic-color behavior, not just accepting the flags.
- Add the remaining reference global CLI surface: `--include-effects`,
  `--exclude-effects`, and `--print-completion`.
- If byte parity becomes a goal, add a shared virtual-clock/frame-capture
  harness and then reconcile random draw order and each effect's intermediate
  choreography. The current renderer intentionally has a different terminal
  stream.

## Credit and license

The effect ideas, art direction, and CLI contract originate with
[TerminalTextEffects](https://github.com/ChrisBuilds/terminaltexteffects) by
ChrisBuilds, via the vendored Rust `ttfx` reference. `otfx` retains that
attribution while using an independently structured Odin implementation.

MIT licensed; see [LICENSE](LICENSE) and the reference notices in
[`third_party/ttfx`](third_party/ttfx).
