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
| `random.odin` | The single random stream: seeding, bounded and float draws, shuffle |

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
Layers are priorities in the inclusive range 0 through `max(u32)`. They do not
index a per-layer allocation. Larger layers win; particle ID breaks ties.

Direct initialization of particle columns is allowed during build, before their
first compose. After admission, use setters for coordinate, visibility, layer,
and appearance changes. Visibility is the sole admission control; there is no
separate frame-selection slice or external dirty-marking obligation.
`engine_make(input, cfg)` uses `context.allocator` throughout construction.

## Storage and ownership

Particles use `#soa[dynamic]Particle`. Coordinates and requested layers are native
integers; `Particle_Id` is distinct u32, with `max(Particle_Id)` reserved as
`NO_PARTICLE`. `Appearance_Id` is u32 and indexes shared appearance storage.
A particle owns its current and initial glyph (`rune`), coordinates, appearance
IDs, optional private appearance, visibility, and layer. Glyphs are independent
of styling. Its renderer-owned `cell` records published membership, or -1 when
absent; it has no membership slot, links, or encoded packet.
`Particle_Groups` uses flat `members` and `spans`.

`Particle.flags` is `bit_set[Particle_Flag; u8]`: `Visible`, `Fill`,
`Preserve_Initial_Colors`, `Update_Queued`, `Placement_Changed`, and
`Content_Changed`. The first three describe requested state/classification;
setters accumulate change flags and composition clears them. SoA stores one
contiguous flags column. Set/clear individual bits with `+=`/`-=` rather than
overwriting the flag byte. Fields retain natural alignment without packed,
unaligned access.

`updates` is a reusable array of four-byte `Particle_Id` values. The particle
gathers final requested values and change flags; `Update_Queued` deduplicates
publication. No queue entry copies the previous placement. The particle's
published cell and its render node's published key supply that information.
Initialization queues new IDs through the same path. Capacity follows particle
capacity; no separate admission scan or full particle/cell-grid scan is required.

Each particle has one 24-byte renderer-owned `Render_Node`, containing native
intrusive-list links and a packed 64-bit `(layer, particle ID)` key.
`xar.Array(Render_Node, 2)` supplies stable addresses and direct ID lookup.
Preparation runs after engine/effect build and on population growth; the usual
frame path checks population length once. This also supports Thunderstorm's
playback-created particles. One reusable key array reserves against particle
capacity for winner resolution.

A 24-byte `Render_Cell` contains its intrusive-list header, winning ID,
`unordered`/`needs_resolve` flags, and the encoded length of its slot. Arrivals append and
compare their published key with the cached winner. An append below the previous
tail marks the list unordered. Departures unlink their exact node directly;
covered departures need neither a scan nor pixel dirtiness. An ordered winner
departure exposes the tail. An unordered winner departure queues that cell once,
clears its winner, and defers resolution until all queued particle changes finish.

Composition drains each queued ID once, unlinking old membership and appending
final membership only when its cell or layer changes. Published node keys stay
independent of other particles' requested layers. Content-only updates dirty
only their current winning cell. Pending cells gather and sort their surviving
keys once, reconnect the same nodes, and publish the maximum-key winner. Then
encoding sees only final winners. There are no per-cell dynamic arrays,
insertion shifts, tombstones, or compaction passes. See the
[intrusive-list measurements](intrusive-lazy-stack.md) and
[current integrated benchmark](intrusive-main.md) for results and known tradeoffs.

`rows[row].cells[column]` gives the row-oriented grid view. Each `Render_Row`
borrows a slice of the same contiguous `cells` allocation used by flat cell
indexing; these are two views of one grid, not duplicate state. The winning
particle supplies its glyph and appearance; there is no second appearance-ID grid.
`slots: [][SLOT_MAX]byte` holds each cell's encoded bytes, indexed like `cells`.
`patch_cell(e, index)` encodes the winner into its slot, or a single space when
the cell empties, which erases the departed glyph and advances the cursor.
`cell_encoding(e, index)` returns exactly what the terminal last received for
that cell. Slots are allocated once and remain fixed for the engine's lifetime.

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

`Appearance` contains `colors: Color_Pair`, `bold`, an encoded style prefix with
its length, and a dirty flag. The prefix holds bold and each set color lane as one
fixed-width SGR field (`ESC[38;2;rrr;ggg;bbbm`), at most 42 bytes. Every styled
cell ends in a reset, so unset lanes need no field; plain and no-color
appearances have length zero. There is no `using`. Each
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
Ordinary setters detach local edits from shared appearances. Shared appearances
never change once prepared: selecting the ID a particle already uses is a no-op,
and a different style is a new prepared appearance or a local edit. All queued
publication happens before any prefix is encoded.

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
and validation are in [the integrated report](intrusive-main.md). The previous
[unified publication](unified-publication.md),
[cell byte views](cell-byte-views.md),
[packed particle flags](particle-flags.md),
[requested state](requested-state.md),
[gathered updates](gathered-updates.md),
[immediate particle updates](particle-queue.md) and
[uncoalesced commands](deferred-actions.md) experiments remain preserved.

## Frame emission

Changed winners mark a cell in `dirty_cells`, an Odin `bit_array.Bit_Array`;
repeated changes coalesce. Frame construction patches only marked cells,
including cells that became blank, then swaps `dirty_cells` with `emit_cells`.
Construction marks every cell, so the first frame paints the whole canvas.

`frame_output` walks `emit_cells` in ascending order and writes one contiguous
frame into the engine-owned `output` buffer: the frame origin, then each run of
adjacent changed cells. A run starts with a cursor-next-line (`ESC[nE`) when its
row differs from the cursor's, and a cursor-character-absolute (`ESC[nG`) unless
it starts in column one. Unchanged cells never reach the terminal, and absolute
columns keep glyph-width differences from drifting along a row. Each slot is
copied whole at its fixed size, and the frame advances only past the cell's
encoded bytes, so slot padding is never emitted. `output` is sized at
construction for the worst case, every cell its own run with both moves.

`print_frame` writes that buffer with `write_all`, which retries short writes
from the exact byte and handles EINTR. `frame_bytes(e, allocator)` returns a
copy without the frame origin; its allocator defaults to
`context.temp_allocator`. Emit or capture before advancing the effect again,
because both read the engine's buffers. A captured copy remains independent
until its allocator is reset or the caller deletes it.

The playback loop owns temporary memory: consume captures and scratch data,
then reset `context.temp_allocator` exactly once at the end of each iteration.
The CLI uses a loop-scoped `defer free_all(context.temp_allocator)` so breaks
and resize exits also clean up. `frame`, `frame_build`, `compose_frame`, and
output helpers do not reset it. Phase and parity/accuracy/docs loops own their
cleanup in the same way.

`compose_frame` updates admission independently of emission. Pending cell
changes survive composition-only calls. Slots and the output buffer are
allocated once at construction and never grow during playback.
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
