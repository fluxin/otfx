# Engine consolidation

The subsequent [cell-array experiment](cell-array-experiment.md) replaces the
linked-list ownership described here and is currently retained as unfinished
work. The measurements below describe the earlier consolidation stage.

This change removes renderer state that can be derived from the working path.
Incremental overlap ownership, prepared/mutable visual storage, setter guards,
and sparse-patch/dense-rebuild row encoding remain intact.

- Visibility is the sole admission control. The optional selection API, candidate
  list, alternating generation, and per-particle selection column are removed.
  Composition visits only particles created since the previous composition.
- `frame_visuals` is removed. A cell's winning particle already owns its visual ID.
- `Render_Cell` groups the winner and occupant-list head. `Render_Row` groups its
  cell slice, byte buffer, offsets, change count, and dirty/valid/emission flags.
  `rows[row].cells[column]` and flat `cells[index]` view one contiguous allocation.
- `output_parts` and `capture_buf` are removed. Terminal descriptors are local to
  `print_frame`; contiguous capture allocates only when explicitly requested.
- The unused constructor allocator argument, decimal writer, rectangle helper,
  and single-call dirty-row wrapper are removed.

Engine source decreases from 2,570 to 2,517 lines. More significantly, there is
one admission rule, one cell grid, one retained row representation, and no
persistent descriptor list or capture copy.

## API changes

Use `engine_make(input, cfg)` with `context.allocator`. `frame`, `frame_build`,
and `compose_frame` no longer accept an optional particle selection; hide/show
through `set_particle(..., visible = ...)`. Existing effects and tools already
used this path. Selection-only tests now exercise visibility removal/re-entry.

`frame_bytes(e, allocator)` returns an independent copy, defaulting to the
temporary allocator. Keep a copy longer by passing the appropriate allocator.
Render or capture before further particle mutations because live row bytes are
still borrowed by terminal output.
The playback loop resets temporary memory once at the end of each iteration;
frame construction and output helpers never reset it.

## Validation

- 48 native tests pass, both with and without frame instrumentation, including
  allocation-free bounded playback and a new capture-ownership witness.
- 222 deterministic captures are byte-identical to the frozen pre-change binary.
- Three additional tall canvases (1x1100, 2x513, 3x1025) are byte-identical,
  exercising output beyond the 1,024-descriptor syscall batch.
- Source, phase instrumentation, parity, accuracy, and docs tools check cleanly.
- The parity run covers 37 effects with zero failures (13 exact frame counts,
  24 already-diagnostic differences against the non-ASM reference).

## Full-suite result

[All 35 effects](engine-consolidation-benchmark.tsv) retain their frame counts.
Mean best wall time is **48.4 to 48.5 ms**, mean child CPU is **48.4 to 48.4 ms**,
and average peak RSS is **11.3 to 11.1 MiB**. Geometric speedup is **1.00x**:
the consolidation preserves aggregate throughput rather than improving it.

Errorcorrect is the only effect more than 2% slower in the full run,
**24.4 to 25.1 ms (+2.9%)**. Individual rows in the TSV include all other
improvements and regressions; an unchanged aggregate does not imply every
effect is unchanged.

A reversed-order follow-up (five samples, at least one second each) confirms
Errorcorrect at **24.4 to 25.1 ms**. Laseretch is **62.4 to 62.7 ms**, within 1%.
The Errorcorrect cost is retained and reported as a tradeoff of this simpler
implementation, not dismissed as measurement noise.

## Measurement protocol

Both binaries use `-o:speed -microarch:native -debug` with bounds checks. The
baseline is source revision `7cf8e2ed`. Full CLI runs use CPU 2, seed 1, frame
rate 0, three samples of at least 0.3 seconds, terminal 200x50, input 190x46,
and `/dev/null` output. Matrix/Thunderstorm duration diagnostics are excluded
from the 35-effect aggregate. No compilation or tests overlap measurement.

An isolated eight-effect screen of visual-grid removal measured 40.8 ms mean
best wall time on both sides. Grouping row/cell state then measured 40.6 to
40.3 ms; geometric speedup was 1.00x. These are screens, not full-suite claims.

Raw binaries, captures, screens, and logs are in `/tmp/otfx-distill-20260926`.
The harness labels its reference column `rust`; both columns in this comparison
are Odin binaries. This change does not refresh the ASM oracle.
