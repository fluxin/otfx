# Engine and playback contracts

## Shared performance paths

Effects with the same operations use the same implementation so improvements
carry across existing and future effects. Effects own choreography, phase
transitions, random order, and completion; the engine owns appearance encoding,
mutation invalidation, raster membership, and emission.

- Build reusable appearances with `prepare_visual`; publish prepared IDs and
  dynamic values through `set_visual` or the appearance setters. Both forms
  preserve one logical appearance, read through `get_visual`, and the same
  input-color and dirty-state rules. `set_visual_codes` applies parallel ID/code
  slices in order, comparing eight code IDs at a time to skip held blocks.
  Colorshift and Decrypt share this bulk operation. It uses fixed local arrays
  and native SIMD comparisons, without raw-pointer gathers or retained scratch.
- Reuse `sample_timeline_changes` for shared tick-to-sample schedules. It returns
  changed slots into caller-owned scratch; the effect keeps its own completion
  and active-range decisions. Smoke and Decrypt already share this operation.
- Send all rendering through the retained raster and `write_character`.
  A single `strings.Builder` owns output throughout a frame, including cursor
  moves, spaces, prepared bytes, and dynamic visuals. The buffer descriptor is
  published back once after emission, rather than copied for each changed cell.

New bulk or SIMD operations should implement a common data operation used by
real callers, preserve the scalar API's ordering and invalidation contract, and
be validated across their consumers. Do not duplicate encoders or dirty tracking
inside effects, or add a generic playback interpreter to share choreography.

## Ownership and resize

The engine owns `#soa[dynamic]Character` storage, both terminal cell grids in one
allocation, and the reusable ANSI output buffer. Effects write character state
and supply renderer candidates; they do not own another canvas. Layer and
creation index determine painter priority regardless of candidate-list order.
Groups use a flat `Char_Groups.members` pool and explicit `spans`.

The current raster persists across frames. Each cell retains an intrusive list
of visible candidates, indexed by character ID. Coordinate, visibility, layer,
and selection changes invalidate affected cells; only those cells resolve their
maximum `(layer, creation index)` again. Visual-only changes invalidate output
for the current winner without rebuilding membership. The previous raster and
visual cache continue to describe the last emitted state.

Effects can publish renderer-visible settings together:

```odin
visual := engine.get_visual(e, id)
visual.fg = color
engine.set_character(e, id, coord = position, visible = true, visual = visual)
```

`set_character` is forced inline. Omitted settings keep their values and equal
settings do no work. `set_symbol`, `set_foreground`, `set_background`, and
`set_bold` update individual appearance fields; `set_visual` publishes either
a complete `Visual` or a prepared `Visual_Code_Id`. The `visual` argument of
`set_character` accepts either form too. Effects use these setters during playback. The low-level
`mark_character_dirty` remains available for external direct writers and
invalidates both membership and encoded appearance. Explicit direct appearance
edits write `chars.visual[id]` and then mark the character; its logical value is
always current, including after a prepared-code assignment.
Construction marks every
character initially, including added characters, so direct initialization before
the first raster update needs no extra tag. Input state remains immutable.

Odin `bit_array.Bit_Array` owns dirty character, cell, and selection sets. Bits
deduplicate changes without per-character generations or an ID queue. Membership
bits clear after rasterization; output bits remain pending until emission,
including when tools update without emitting. Storage grows with character
capacity. Preallocated marking and membership checks use the library's unchecked
operations, so fixed-population playback does not allocate.

Each character has a naturally aligned 12-byte membership record containing its
cell and two intrusive links. Prepared code IDs occupy a separate contiguous u32
column. A nonzero code selects immutable prepared bytes; `NO_CODE` selects
dynamic encoding. `get_visual` is the logical read API for both forms. One
`Visual` record stays current in either case, so reads and whole-value mutations
do not branch between storage representations. Its fields are consumed together
by the existing effect API. Splitting them into separate columns and deferring
prepared-value publication regressed real effects; packed ID comparisons remain
separate for the bulk API. Equal assignments do no work and preserve the code.
Dynamic visuals retain color number fragments in a 24-byte character-owned
`Encoded_Colors` record: two 11-byte RGB buffers and a `bit_field u16` containing
two four-bit lengths and a validity flag. Changing color invalidates those
fragments; symbol, bold, placement, visibility, and layer changes preserve them.
An actual component edit releases a prepared code. Last-emitted state uses its
own prepared ID or a whole raw `Visual` snapshot, selected by `cached_code`.
`get_emitted_visual` resolves either form; the cached raw snapshot is ignored
while its corresponding prepared ID is active. Preview reads do not
publish last-emitted state.

```odin
// Build once; keep the ID in effect state or a shared timeline.
red := engine.prepare_visual(e, engine.Visual{symbol = "*", fg = RED})

// Playback uses the same setter and renderer for either source.
engine.set_visual(e, id, red)
engine.set_visual(e, id, engine.Visual{symbol = "*", fg = color})
engine.set_character(e, id, coord = position, visual = red)
```

`write_character` appends prepared bytes or assembles dynamic output from cached
color fragments, the existing UTF-8 symbol, and constant ANSI prefixes/resets.
Build and playback share `encode_colors` and `write_visual`. `Always` input-color
overrides cache the effective per-character colors too. No-color output writes
the symbol directly. Configuration and input styles stay fixed for the
engine's lifetime; resize constructs a new world and new caches.

`strings.Builder` writes directly into the prepared pool or destination frame
buffer. There is no 64-byte cache, overflow pool, temporary per-cell `Code_Buffer`,
or runtime interning. Cache size does not depend on symbol length or the presence
of bold, foreground, and background together. Fixed-population playback does not
allocate. Frame emission and preview use the same policy-specialized writer;
only frame emission publishes the last-emitted snapshot. Dynamic assembly
passes symbol/bold and color fragments directly to the common encoder.
The small decimal helper remains shared with cursor formatting; its measured
cost is lower than generic integer formatting in these hot loops.

Effects whose visibility flags define their complete work set return `nil` for
all-character rendering: this consumes only marked changes. A selected slice
still restricts membership when needed, but its bitmap is rebuilt to detect
entries and departures. Fixed candidate sets need no redundant selection list.

One `mem.Dynamic_Arena` backs the engine/effect world for a CLI run. A settled
terminal resize ends playback, resets that arena while retaining its blocks,
and constructs a replacement world. No references into the old world survive.
Construction and resize use the same `Render_Layout` calculation. Redirected
output does not enable the terminal-resize handler.

Decoded input and initial fill populations are counted before construction.
Their SoA columns are resized once per population, then initialized directly;
build does not repeatedly append and scatter a full character row. Added
characters retain the growable path and extend all character-indexed bit arrays.

When an effect knows its added population, the engine manages capacity for the
characters, added IDs, and dirty/selection bits together:

```odin
characters := engine.character_batch(e, count)
for position in positions {
    id := engine.add_character(&characters, "*", position)
    engine.set_character(e, id, visible = true)
}
```

The batch permits up to `count` additions. IDs stay stable; no borrowed column
slices survive growth. Callers do not inspect engine lengths or reserve its
internal arrays. For incremental creation, `add_character(e, symbol, position)`
still grows storage automatically.

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
