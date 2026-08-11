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

Measurements run each real CLI with frame pacing disabled (`--frame-rate 0`),
the same dense input, terminal dimensions, and seed. RSS is `/usr/bin/time`
maximum resident set. They are useful production measurements, but not a
byte-parity benchmark: `otfx` intentionally renders dirty runs while `ttfx`
redraws through its reference path.

| Workload | ttfx Rust | otfx Odin | Observed result |
|---|---:|---:|---:|
| Rain | 0.57 s / 110.5 MiB | 0.19 s / 45.2 MiB | 3.0× faster, 2.4× lower RSS |
| Pour (`--pour-speed 1 --gap 4`) | 2.69 s / 129.0 MiB | 0.96 s / 39.0 MiB | 2.8× faster, 3.3× lower RSS |
| Waves (`--wave-count 15`) | 1.84 s / 1.83 GiB | 0.20 s / 12.2 MiB | 9.2× faster, 153× lower RSS |
| Colorshift (`--cycles 12`) | 1.94 s / 495.8 MiB | 0.07 s / 12.0 MiB | 27.7× faster, 41× lower RSS |
| Fireworks (defaults) | 0.75 s / 255.2 MiB | 0.33 s / 13.3 MiB | 2.3× faster, 19× lower RSS |
| Bubbles (`--bubble-delay 1`) | 0.64 s / 158.3 MiB | 0.27 s / 12.5 MiB | 2.4× faster, 12.7× lower RSS |
| Startup (`slide`, `x`) | 1.2 ms | 1.2 ms | Equal on the current host; latency only |

### Matrix is not a normalized speedup number

`matrix` has a wall-clock-gated rain phase. With `--rain-time 5`, both programs
intentionally occupy about five seconds, so elapsed time cannot establish a
meaningful speedup. The current long run is **5.34 s / 80.8 MiB** for Rust and
**5.01 s / 29.8 MiB** for Odin. That shows a lower RSS footprint, but the
1.07× elapsed ratio is **not** a throughput claim.

There is a second reason to keep Matrix off a normalized chart: within that
fixed wall-clock window, the two renderers can produce different numbers of
frames: the current 200×50 run emitted **107,399 Rust frames** and **900,604
Odin frames**. These are an observed sample, not stable metrics: scheduler and
host throughput change the count. A fair Matrix comparison needs a shared
virtual clock and fixed logical frame count; that harness is not implemented
yet.

`thunderstorm` has the same timing property through `--storm-time`; the
benchmark sweep includes it with `--storm-time 1` for end-to-end and RSS
observation, but it is also excluded from normalized speedup claims. At 200×50
one sample one-second storm emitted **4,813 Rust frames** and **55,920 Odin
frames**; those counts vary with scheduling just as Matrix does.

The same caution applies in lesser degree to every row above: the numbers are
end-to-end user-facing throughput and memory, not proof of equal intermediate
frames. Do not interpret them as a semantic-parity benchmark.

Run the current production benchmark with:

```sh
odin build src -o:speed -out:otfx
python3 bench/bench.py 5
```

`bench/bench.py` uses a 200×50 canvas, disables pacing, batches short effects
into multi-second samples, and prints frame counts next to elapsed time. Matrix
and Thunderstorm are intentionally labelled as wall-clock gated in its output
and documentation. It includes the same small-input startup comparison as the
performance table.

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
