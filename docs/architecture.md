# Engine and playback contracts

## Ownership and resize

The engine owns `#soa[dynamic]Character` storage, both terminal cell grids in one
allocation, and the reusable ANSI output buffer. Effects write character state
and supply renderer candidates; they do not own another canvas. Layer and
creation index determine painter priority regardless of candidate-list order.
Groups use a flat `Char_Groups.members` pool and explicit `spans`.

One `mem.Dynamic_Arena` backs the engine/effect world for a CLI run. A settled
terminal resize ends playback, resets that arena while retaining its blocks,
and constructs a replacement world. No references into the old world survive.
Construction and resize use the same `Render_Layout` calculation. Redirected
output does not enable the terminal-resize handler.

Output capacity is reserved from the clipped render extent. `frame_emit` clears
the buffer length and reuses its capacity. Fixed-population effect lists reserve
their known bounds during construction; resize recomputes those bounds. Variable
Thunderstorm branches and overlapping sparks may still grow during playback.

## Animation and rendering

Animation remains frame-by-frame. Effects retain compact motion data, traversal
orders, and hold schedules, not whole rendered frames or ANSI diffs. Completed
animation work can stop while its final characters remain renderer candidates.
Effects own completion and final holds; skipping work must preserve the last
coordinate, color, visibility, and layer transition.

`sample_timeline_changes` reads start ticks, previous sample indices, and a shared
tick-to-sample table. It writes changed `(slot, sample)` pairs into caller-owned
scratch in input order, without allocating. Each lane owns its written fields:
initialize the previous sample to `-1` on activation or after another writer
changes those fields. The sampler holds the last sample indefinitely; the caller
owns completion timing. Smoke and Decrypt use this shared primitive.

Odin native easing supplies movement curves. Coordinate quantization uses the
shared ties-to-even helper. Color comparison includes optional-color presence;
the four-byte comparison has static size/alignment guards. String content and
bold state remain part of visual comparison.

Smoke precomputes a weighted spanning tree and breadth-first arrival ticks. Burn
precomputes connected random-frontier ignition ticks. Laseretch precomputes a
depth-first target order, using spaces as traversal bridges. Temporary graph and
queue storage is discarded before playback; their compact replay data persists.

## Thunderstorm

Strike generation and replay live together in `src/effects/thunderstorm.odin`.
Scalar batches advance branch tips using Odin's RNG. Temporary branch spans and
child insertion points are flattened into depth-first reveal order. Once the
final segment count is known, character and replay capacity is reserved before
materialization; generation scratch does not survive into playback.

Playback reveals one to three segments per step. Only the revealed prefix enters
the renderer candidate list. Retirement hides the strike and clears its replay
cursor, retaining pool capacity. There is no fixed cap that silently drops
branches; recursive populations can grow rapidly on tall canvases. Geometry
fidelity does not imply whole-effect parity; see [accuracy](accuracy-review.md).
