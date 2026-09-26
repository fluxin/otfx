# Fixed-width cell bytes with incremental updates

This uncommitted experiment builds on the retained cell-array ownership trial.
Both the cell arrays and this representation remain in the workspace for further
iteration; no performance-based revert or commit is authorized.

## Removed paths

- `Render_Row.offsets`, `valid`, `changes`, `dirty`, and `emit`.
- Per-row dynamic byte allocations, sparse suffix shifting, and dense rebuilding.
- `blank_row`, `append_packet`, and the variable-size output writer.
- In the subsequent single-code-point cleanup: `long_symbol`, its row counter,
  the exceptional output iterator, and unused long-symbol/rebuild statistics.

`Engine.cell_bytes` owns one contiguous allocation. `cell_stride` is 51 bytes
with color enabled and four bytes in no-color mode. `Render_Row.cells` borrows
the cell grid, and `Render_Row.bytes` borrows the corresponding byte-grid slice.
There is no reserve/grow operation for the byte grid.

Setters queue winning cells in a dirty-cell bit array. Frame construction writes
only those slots, then swaps pending and emitted row bit arrays and clears the
pending set. Repeated mutations coalesce. Emission visits set rows in order,
without checking a dirty flag on every row. The completed frame remains intact
while subsequent setters enqueue changes.

The prepared visual packet cache remains. Packets now contain 51 bytes and are
fully padded at encoding time. `patch_cell` selects a cached packet or a padded
blank and copies the fixed slot. It neither checks glyph length nor clears a tail.
The symbol contract is explicitly one valid Unicode code point or empty. Packet
construction asserts the contract; invalid UTF-8 and multi-code-point strings
are rejected rather than truncated. Cells no longer contain string references.
Each row has exactly two borrowed slices, and output consumes its byte slice
directly. The former arbitrary-string compatibility path has been deleted at
the user's request.

The initial fixed-slot change reduced engine source from 2,535 to 2,490 lines.
Removing arbitrary-string support and simplifying `patch_cell` removes another
70 lines, leaving 2,420: 115 fewer than the packed-row cell-array version.

## Initial result, before removing arbitrary-string support

Mean best wall time across the 35 finite effects improves from **53.3 to 50.0 ms**
(6.2% less time). Mean child CPU improves from **53.2 to 50.1 ms**; average peak
child RSS remains **11.9 MiB**. Geometric wall speedup is **1.03x**. All frame
counts match. This improves the current cell-array version on average; it is not
a claim that every effect improves or that the older linked-list baseline is
beaten.

| Effect | Packed rows, ms | Fixed cells, ms | Change |
|---|---:|---:|---:|
| Errorcorrect | 26.1 | 16.2 | -37.9% |
| Bouncyballs | 59.9 | 44.7 | -25.4% |
| Bubbles | 100.4 | 76.3 | -24.0% |
| Laseretch | 64.5 | 55.6 | -13.8% |
| Colorshift | 16.7 | 27.7 | +65.9% |
| Waves | 20.4 | 27.3 | +33.8% |
| Overflow | 25.8 | 31.2 | +20.9% |

The full TSV records every improvement and regression. These are matched
three-sample results; small differences have not been confirmed with longer
reversed-order runs. The large regressions remain diagnostic targets. No profile
has yet apportioned the costs of deferred cell writes, dirty-bit iteration,
padding writes, and the extra per-cell long-symbol state.

## Single-code-point cleanup result

Deleting the arbitrary-string path and making `patch_cell` one padded copy
improves the next matched 35-effect run from **50.0 to 48.5 ms** mean best wall
time. Mean child CPU is **50.0 to 48.5 ms**; average peak child RSS is **11.9 to
11.8 MiB**. Geometric speedup is **1.03x**, and all frame counts match.

This comparison uses the preceding fixed-slot binary as its baseline, isolating
the 70-line cleanup. [All 35 results](single-symbol-benchmark.tsv) include Spray,
which measures **57.0 to 58.2 ms (+2.1%)** and has not had a longer noise check.
This does not erase regressions against the earlier packed-row renderer, such
as Colorshift. No new ttfx ASM comparison is claimed.

The native test run has 52 tests: 48 pass, including both symbol-rejection tests,
and the same four cell-array allocation assertions fail. Source and instrumented
phase-tool checks pass. Trial artifacts and its separate diff are retained under
`/tmp/otfx-single-symbol-20260926`.

## Validation and output

### Counted row cursor commands

The subsequent cursor cleanup removes `Engine.row_moves`, its allocation, and
the repeated-command slicing. Each row gap now emits one `ESC[nE`; adjacent rows
borrow the constant `ESC[1E`. Larger gaps use stack scratch storage that remains
live until its writev batch completes. Engine source is now 2,430 lines: removing
the retained buffer adds ten net lines for counted formatting and its callers.

The matched 35-effect screen measures **48.5 to 48.8 ms** mean best wall, **48.5
to 49.0 ms** mean child CPU, and **11.7 to 11.8 MiB** average peak RSS. All frame
counts match; this is not a measured performance improvement. The full
[counted-row results](counted-rows-benchmark.tsv) include Blackhole **82.7 to
87.9 ms (+6.3%)** and Errorcorrect **15.0 to 15.4 ms (+2.7%)**. A reversed-order
five-sample check with one-second minimum samples gives Blackhole **82.9 to
83.0 ms** and Errorcorrect **15.0 to 15.4 ms** (before to after): the Blackhole
regression did not repeat, while the small Errorcorrect regression did.

All 222 libvterm comparisons preserve every displayed cell and cursor after
each frame. Bytes intentionally differ for gaps larger than one row. A separate
1,200-row output check matches `print_frame` against `frame_bytes` across writev
batch boundaries and a 1,000-row jump. Native tests remain 48/52 with the same
four allocation failures; parity reports zero failures (13 exact frame-count
matches and 24 diagnostic differences). Source and instrumented phase checks
pass. The first counted-command attempt measured 49.2 to 50.8 ms; its binary and
log remain beside the final trial under `/tmp/otfx-counted-rows-20260926`.
No experiment was reverted or committed.

### Earlier fixed-slot validation

The 222 CLI fixtures match through libvterm: every displayed cell and the cursor
position after every frame. Removing NUL padding also produces identical byte
streams. Raw output is intentionally different and is not called byte-identical.

Existing exact protocol tests compare all non-NUL bytes. New tests check shared
row/grid storage, constant neighbor offsets, clearing a shorter glyph's padding,
and isolation of completed emission from subsequent pending changes. The four
pre-existing cell-array playback-allocation failures remain; their assertions
have not been relaxed.

After deleting arbitrary-string support, all 222 fixtures remain byte-identical
to the preceding fixed-slot binary. The wide-canvas test still covers 65,537
columns and four-byte UTF-8 glyphs; its former multi-megabyte-symbol requirement
is intentionally removed with that API contract. New assertion tests verify
rejection through both prepared visuals and direct symbol setters.

Plain small-fixture output grows from 15,127,459 to 61,535,079 bytes (4.07x).
No-color grows 2.64x, xterm/Unicode 3.36x, and clipped fixtures 1.92x. These are
40x12 fixture totals across 37 effects, not the dense CLI timing workload.
Libvterm validation is not a physical-terminal timing measurement.

## Benchmark protocol

The baseline is the frozen cell-array version with packed row bytes immediately
before this edit. Both binaries use `-o:speed -microarch:native -debug` with bounds
checks. Full CLI runs use CPU 2, seed 1, frame rate 0, terminal 200x50, input
190x46, stdout `/dev/null`, and three samples of at least 0.3 seconds per side.
CPU is child `wait4` user+system time and RSS is peak child RSS. No compilation,
unit tests, or capture runs overlap the measured run.

The harness's `rust` column is the frozen Odin baseline, not ttfx ASM. This trial
does not refresh the ASM oracle. Every effect is reported in
[fixed-cell-benchmark.tsv](fixed-cell-benchmark.tsv).

Frozen source, binaries, test logs, libvterm comparisons, raw benchmark logs,
and the trial-only diff are under `/tmp/otfx-fixed-cells-20260926`.
