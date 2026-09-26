# Engine and playback contracts

Effects own choreography, random order, phase transitions, and completion. The
engine owns clipping, overlap resolution, appearance encoding, dirty tracking,
and terminal output. Effects use the same setters regardless of how they animate.

## Effect API

Build creates particles, reusable visuals, motion data, and schedules. During
playback, publish changes through the setters and return whether a frame is ready:

```odin
red := engine.prepare_visual(e, engine.Visual{symbol = "*", fg = RED})

// Either a prepared Visual_Id or a dynamic Visual uses the same publication API.
engine.set_particle(e, id, coord = position, visible = true, visual = red)
engine.set_foreground(e, id, color)
engine.set_symbol(e, id, "░")

// The runner calls frame and print_frame after a successful effect step.
produced := effects.next_frame(&effect, e)
```

`next_frame` and each effect's `*_next` return `bool`. Visibility determines what
can be rendered; effects no longer return or maintain a second render-ID list.
Omitted `set_particle` settings keep their values. Equality guards avoid repeated
publication. `set_visual` accepts `Visual` and `Visual_Id`; `get_visual` reads the
current logical value in either case. `set_visuals` applies parallel particle and
prepared-visual slices in order, preserving repeated-ID semantics.

Direct initialization of particle columns is allowed during build, before the
first compose. After admission, use setters for coordinate, visibility, layer,
and appearance changes. There is no external dirty-marking obligation. A tool
can still pass an explicit particle slice to `compose_frame` or `frame_build`:
no selection means all particles, while an explicit empty slice means none.
The engine owns the previous selection because callers may overwrite their slice.

## Storage and ownership

Particles use `#soa[dynamic]Particle`. Coordinates and particle IDs are native
integers; `Visual_Id` is u32. A particle stores initial coordinates and visual ID,
current coordinates and visual ID, visibility, layer, and renderer membership.
Initial input style and glyph are resolved through `get_initial_visual`.
`Particle_Groups` uses flat `members` and `spans`.

A cell stores its winning particle and visual ID. Intrusive previous/next links
connect the visible, admitted particles at that cell. Coordinate and visibility
changes unlink/link immediately; layer changes reconsider the winner. Priority
is highest layer, then highest particle ID, independent of selection order.
When a winner leaves, only that cell's remaining occupants are examined.
Unchanged all-particle admission does not scan the population each frame.

Prepared visuals are immutable and interned at build time. Each particle also
has a reserved mutable visual entry. Editing a prepared appearance first copies
its logical value into that slot; subsequent edits mutate the same entry.
`Packet_Fields`, an Odin `bit_set`, identifies which encoded fields need updating.
There is no runtime interning for ordinary appearance changes.

The cached packet has 52 bytes plus u8 prefix and length fields. It encodes the
common glyph of up to four UTF-8 bytes, optional foreground/background, and bold.
Long symbols retain their full string and use prefix/string/reset emission.
Input-color policy and no-color mode share this encoding path. `write_particle`
provides previews from the same packet without changing renderer ownership.

## Row emission

The engine retains encoded bytes and cell offsets per viewport row. A winning
appearance change of unchanged encoded length can overwrite those bytes directly.
Other changes mark a cell in Odin's `bit_array.Bit_Array`; repeated marks are
deduplicated. Sparse changed cells splice their exact byte lengths into the row.
If more than one eighth of a row changes length or owner, the row is rebuilt once
from cached packets. No padding or unused glyph bytes are sent to the terminal.

Dirty rows preserve the existing output protocol: emit each whole changed row,
including blanks that erase departed particles. One slice per row plus cursor
moves replaces one slice per cell. `print_frame` submits those slices through
`writev`, retaining partial-write and EINTR handling. `frame_bytes` concatenates
only for consumers explicitly requesting a contiguous capture. There is no
second previous-cell grid or whole-animation output cache. Output slices borrow
row storage: emit or capture the frame before advancing the effect again.

`compose_frame` updates admission independently of emission. Pending row/cell
changes survive composition-only calls. Row storage is reserved from viewport
width for the common four-byte glyph case; arbitrary long symbols can grow it.
Playback storage tests enforce allocation-free bounded cases.

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

Shared geometry uses Odin math/linalg and paired SIMD ties-to-even coordinate
rounding. `sample_timeline_changes` returns changed sample slots in input order;
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
