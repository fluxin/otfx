# Engine and playback contracts

Effects own choreography, random order, phase transitions, and completion. The
engine owns clipping, overlap resolution, appearance encoding, dirty tracking,
and terminal output. Effects use the same setters regardless of how they animate.

## Source layout

All files remain in the `engine` package. Keep related types and operations
with their existing owner; file boundaries do not add runtime layers.

| File | Responsibility |
|---|---|
| `engine.odin` | Engine state, construction, playback clock, and pacing |
| `particle.odin` | Particle IDs/storage, population creation, batches, glyph and placement setters |
| `group.odin` | Queries, filters, ordering, spans, groups, and group reveal |
| `codes.odin` | Appearance types/storage and setters, cell ANSI encoding |
| `batch.odin` | Frame timelines, hold expansion, and batched sample changes |
| `render.odin` | Cell ownership, dirtiness, and row construction |
| `output.odin` | Terminal I/O, cursor lifecycle, resize signals, and capture |
| `stats.odin` | Optional renderer instrumentation |
| `config.odin` | Terminal settings and input-color policy |
| `canvas.odin` | Canvas bounds, anchors, layout, and viewport clipping bounds |
| `input.odin` | Input decoding, escape/SGR handling, and input-particle materialization |
| `geometry.odin` | Coordinates, path geometry, rounding, and easing names |
| `color.odin` | RGB/xterm conversion, gradients, and brightness |

## Effect API

Build creates particles, shared appearances, motion data, and schedules. During
playback, publish changes through the setters and return whether a frame is ready:

```odin
red := engine.prepare_appearance(e, engine.Appearance{colors = {fg = RED}})
id := engine.add_particle(e, '*', red, position)
other := engine.add_particle(e, 'A', red, other_position)

// Single-field overloads have dedicated implementations.
engine.set_particle(e, id, position)
engine.set_particle(e, id, engine.Visible(true))
engine.set_particle(e, id, engine.Layer(2))

// Combined placement requires all three values and updates membership once.
engine.set_particle(e, id, coord = position, visible = true, layer = 2)

// Appearance is separate: either a shared Appearance_Id or a local Appearance.
engine.set_appearance(e, id, red)
engine.set_foreground(e, id, color)
engine.set_symbol(e, id, '░')

// The runner calls frame and print_frame after a successful effect step.
produced := effects.next_frame(&effect, e)
```

`next_frame` and each effect's `*_next` return `bool`. Visibility determines what
can be rendered; effects no longer return or maintain a second render-ID list.
`set_particle` is a procedure group over `Coord`, distinct `Visible` and `Layer`,
and the complete placement tuple. `Particle` holds requested state. Setters change
that state immediately; getters and previews see it immediately. They also enqueue
the particle once for renderer publication. They do not alter cell membership,
encode appearance bytes, or emit rows. `set_placement` requires all three values
and uses one equality check before assigning them together. Single-field setters
have dedicated implementations.

The particle itself gathers final values: repeated setters overwrite requested
fields, and equality guards compare against those current values. The renderer
reads the final result once per queued particle. A move out and back before
rendering does not change membership, though publication may repatch the winner.
`set_appearance` accepts `Appearance` and `Appearance_Id`; local edits and shared
assignments take effect in call order. `set_appearances` applies parallel slices
in order. There is no command union, pending-value copy, or field-mask interpreter.
Adding a requested property requires its storage, setter, and rendering behavior;
it does not require another pending representation or dispatch case.
The [placement API measurements](placement-api.md) record the rune/color-pair
migration, frozen comparison, and remaining validation failures.
Layers are nonnegative array indices. Use a small, dense range: a cell allocates
layer headers through the highest index it has used. Negative layers are rejected.

Direct initialization of particle columns is allowed during build, before their
first compose. After admission, use setters for coordinate, visibility, layer,
and appearance changes. Visibility is the sole admission control; there is no
separate frame-selection slice or external dirty-marking obligation.
`engine_make(input, cfg)` uses `context.allocator` throughout construction.

## Storage and ownership

Particles use `#soa[dynamic]Particle`. Coordinates and particle IDs are native
integers; `Appearance_Id` is u32 and indexes `shared_appearances: [dynamic]Appearance`.
A particle owns its current and initial glyph (`rune`), coordinates, appearance
IDs, optional private appearance, visibility, and layer. Glyphs are independent
of styling: different glyphs can use the same appearance ID. Initial appearance
and glyph remain available after edits. Renderer membership belongs to cells;
particles have no stored membership slot, links, or encoded packet.
`Particle_Groups` uses flat `members` and `spans`.

`Particle.flags` is `bit_set[Particle_Flag; u8]`: `Visible`, `Fill`,
`Preserve_Initial_Colors`, and `Update_Queued`. The first three describe requested
state/classification; only the renderer manages `Update_Queued`. Sharing their
storage does not change their owners. Set/clear individual bits with `+=`/`-=`;
do not overwrite the flag byte when changing one property.

SoA stores one contiguous flags column; it does not pack separate boolean fields.
The fields are ordered by natural alignment: coordinates/layer (8), IDs/glyphs
(4), then appearance and flags (1). No unaligned packed struct is needed.
On this 64-bit build, `size_of(Particle)` is 112 bytes (previously 128), and the
SoA header is 104 bytes (previously 128). Actual column payload drops from 113
to 110 bytes per capacity slot, plus per-column alignment: the measured buffer
at 10,000 slots is 1,100,000 bytes, previously 1,130,000.

`updates` is a reusable contiguous array of 24-byte `Particle_Update` entries:
`{id, previous_cell, previous_layer}`. The first change snapshots the published
placement before modifying the particle. The `Update_Queued` flag deduplicates
subsequent changes; there is no pending-index table. Queue capacity follows
particle capacity. Initialization queues each new particle with `previous_cell = -1`;
subsequent build edits deduplicate into that entry. New and existing particles
use the same publication loop, with no separate admission count or scan.

Composition removes every changed old membership before inserting final requested
placements. This order matters because other queued particles already hold their
requested layers, which may differ from their published layers. Appearance/glyph
changes leave membership intact. Final winning cells are marked for encoding;
then the queue flags and entries are cleared. Publication belongs in `render.odin`.

A cell stores `layers: [dynamic][dynamic]Particle_Id`, indexed directly by layer.
There is no stored layer tag or layer lookup. `top` caches the winning ID, or -1
for an empty cell. Insertion grows the outer array if needed and appends the ID
to `cell.layers[layer]`. A single comparison against the cached winner preserves
the `(layer, particle_id)` priority; arrival order does not decide visibility.
Removal linearly locates the ID within its layer and uses `ordered_remove`.
Only removal of the winner triggers a replacement scan: walk layer indices
backward to the first nonempty array, then take its maximum particle ID.
The entry's previous cell and layer identify membership to remove for
movement, layer changes, hiding, and clipping. Particles retain their requested
layer while hidden or clipped. Setters do not mutate cell membership or rows.
This [indexed-layer experiment](indexed-layers.md) retains both unordered and
ordered-removal variants for comparison. Playback allocation gates remain open.
The engine visits queued particles, including newly created ones. There is no
separate admission scan, full particle scan, or cell-grid scan per frame.

`rows[row].cells[column]` gives the row-oriented grid view. Each `Render_Row`
holds only a borrowed cell slice and a borrowed byte slice.
Row slices borrow the same contiguous `cells` allocation used by flat cell
indexing; these are two views of one grid, not duplicate state. The winning
particle supplies its glyph and appearance; there is no second appearance-ID grid.
Each `Render_Cell.bytes` also borrows its fixed-width slot in `canvas_bytes`.
Clearing an occupied cell copies `Blank_Cell`: one space to erase the glyph
and advance the cursor, followed by NUL padding. An all-NUL slot would not erase
the previous terminal glyph. The same template serves both slot widths.
Construction sets these views once; `patch_cell(e, &cell)` writes through that
slice. Cells, rows, and the flat canvas share bytes, with no per-cell allocation
or duplicated packets. The canvas allocation remains fixed for the engine's
lifetime. This adds one 16-byte slice header per cell on the 64-bit build.

`prepare_appearance(e, appearance)` appends a value and returns a new ID every
time. There is no lookup map or deduplication in this creation API. `add_particle(e, glyph, appearance_id, position)` requires an existing ID.
`init_particle` initializes a fresh storage slot with that glyph, ID, and position;
initial and current references start equal. Both it and `set_symbol` live in
`particle.odin`. Constructors do not create appearances or choose sharing policy.

Callers explicitly reuse IDs. Fill particles share one plain appearance;
Binarypath's zeroes and ones share a plain appearance too. Colorshift retains
only its gradient appearance palette, with no symbol-to-palette map. Decrypt
keeps glyph indices separate from its ciphertext appearance palette. Input
loading creates initial appearances and applies its existing color policy.

`Appearance` contains `colors: Color_Pair`, `bold`, a 43-byte encoded style
prefix, and a dirty flag. The prefix has no stored length: styled output uses
all 43 bytes; plain/no-color output omits it. There is no `using`. Each
color channel remains optional so terminal default and explicit black are distinct.
A nonzero `shared_appearance_id` selects the shared value; zero selects the
particle's `private_appearance: Appearance`. A local style edit detaches that
style without changing the shared value. Selecting a shared ID again replaces
the private style. Changing a glyph never detaches its appearance. There is no
per-field override merge. Equal field assignments remain no-ops.

Creation and style setters mark the appearance dirty without encoding it.
`dirty_appearance(^Appearance)` only sets this flag. Setters separately queue the
particle. Rendering reconciles requested placement and marks affected top cells,
then encodes each stale appearance on first use. Other queued cells using it
reuse the prepared prefix even after its dirty
flag clears. Hidden/covered private appearances remain dirty until exposed.
Glyph edits and appearance-ID switches queue publication without invalidating
unchanged appearance bytes. Patching a cell marks its row for output.
`set_appearance` compares only colors and bold and ignores supplied cached bytes.
Ordinary setters detach local edits from shared appearances. A caller directly
editing shared storage must invalidate its prefix and queue `set_appearance`
with that shared ID for every affected particle; the dirty flag alone is not a
broadcast notification. All queued publication happens before any prefix is encoded.

The renderer copies that prefix, encodes the particle's rune, appends the reset,
and clears the cell slot's unused tail. There are no glyph or appearance maps.
Particles retain no complete packet or `Packet_Fields`; prefixes belong to
appearances. `.Always` selects the initial appearance for rendering.

`write_particle` prepares a local appearance copy when needed and uses the same
packet writer with a local 51-byte buffer. It does not populate retained prefixes
or clear their dirty flags, and it previews requested values immediately. Renderer
encoding happens only for dirty cells.

Rune zero means no glyph. Input and effect symbol collections store runes,
without per-glyph string allocations. Symbol setters and constructors validate
Unicode scalar values. CLI symbol flags reject multi-scalar arguments and
malformed UTF-8. This is a code-point contract, not a grapheme or display-width
guarantee. See [appearance ownership measurements](appearance-ownership.md) and the
[renderer cache experiment](render-cache.md) and
[appearance-prefix measurements](appearance-bytes.md). Current queue measurements
and validation are in [unified publication](unified-publication.md). The previous
[cell byte views](cell-byte-views.md),
[packed particle flags](particle-flags.md),
[requested state](requested-state.md),
[gathered updates](gathered-updates.md),
[immediate particle updates](particle-queue.md) and
[uncoalesced commands](deferred-actions.md) experiments remain preserved.

## Row emission

The current [fixed-cell experiment](fixed-cell-experiment.md) uses one engine-owned
`canvas_bytes` grid: 51 bytes per cell, or four in no-color mode. Rows borrow slices into
this allocation. Changed winners mark a cell in Odin's `bit_array.Bit_Array`;
repeated changes coalesce. Frame construction updates only marked cells, including blank cells. Unused
bytes in each fixed slot are cleared to NUL. There are no row
offsets, byte shifts, row reservations, dense-rebuild thresholds, or row rebuilds.

Cells contain no string references. There is no long-symbol path, row counter,
or output iterator: each emitted row is one borrowed byte slice.

Dirty rows preserve the existing output protocol: emit each whole changed row,
including blanks that erase departed particles. Two engine-level row bit arrays
track pending changes and completed emission. Frame construction swaps them and
clears the pending set. Rows have no dirty or emit flags. `print_frame`
constructs stack-local `writev` descriptors directly from those rows and cursor
moves, retaining partial-write and EINTR handling. There is no stored output-part
list. `frame_bytes(e, allocator)` allocates an exact-size contiguous copy only
when requested; its allocator defaults to `context.temp_allocator`. The engine
retains no capture buffer. Emit or capture before advancing the effect again,
because terminal output borrows mutable row storage. A captured copy remains
independent until its allocator is reset or the caller deletes it.

Row gaps emit one counted cursor-next-line command (`ESC[nE`). Adjacent rows
reuse the constant `ESC[1E`; larger gaps are formatted into stack storage that
remains live through `writev`. The engine retains no cursor-command buffer.

The playback loop owns temporary memory: consume captures and scratch data,
then reset `context.temp_allocator` exactly once at the end of each iteration.
The CLI uses a loop-scoped `defer free_all(context.temp_allocator)` so breaks
and resize exits also clean up. `frame`, `frame_build`, `compose_frame`, and
output helpers do not reset it. Phase and parity/accuracy/docs loops own their
cleanup in the same way.

`compose_frame` updates admission independently of emission. Pending row/cell
changes survive composition-only calls. The byte grid is allocated once at
construction and is never grown during playback.
Playback storage tests enforce allocation-free bounded cases. Four currently
fail because the experimental cell arrays grow during playback; those tests
have not been weakened.

## Lifetime and resize

One `mem.Dynamic_Arena` backs a CLI engine/effect world. Settled terminal resize
ends playback and rebuilds the world using the same `Render_Layout` calculation.
No references into the old world survive. Redirected output does not install the
resize handler. Effects may animate outside the viewport; the engine clips at
membership publication, and those particles can later re-enter.

Input and fill populations are counted before SoA initialization. Ordinary
`add_particle(e, symbol, position)` grows storage automatically. A known generated
population can use `particle_batch(e, count)`; callers never reserve internal
renderer arrays. Borrowed SoA column slices must not survive particle growth.

## Shared animation work

Shared geometry uses SIMD nearest rounding in `round_to_int` and `rounded_coord`,
preserving signed ties to even. SIMD was restored after native rounding increased
the 35-effect mean by 4.4%, with larger confirmed effect regressions. The native
and cast-only comparisons are preserved in [rounding experiments](native-rounding.md).
`sample_timeline_changes` returns changed sample slots in input order;
effects retain completion timing and phase ownership. Finished motion or held
color samples may skip calculation while the final particle remains visible.
Rings and Middleout skip unchanged color samples; Decrypt retires completed tails.

Animation still runs frame by frame. Smoke, Burn, and Laseretch precompute compact
traversal/arrival data, not rendered frames. Thunderstorm generates recursive
geometry into reusable particle pools; visibility admits only revealed segments.
Its variable branches and sparks may grow during playback rather than imposing
a cap that drops geometry.

## Diagnostics

Build `bench/phases` with `-define:OTFX_FRAME_STATS=true` for compose, emit, write,
dirty-row, descriptor, patch/rebuild, membership, and byte-copy counters. Normal
builds compile out this instrumentation. Phase timings include instrumentation
cost and do not replace frozen-binary CLI measurements. See
[row renderer measurements](row-renderer.md) for the experiment decisions and
comparison against ttfx's ASM branch.
