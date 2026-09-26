package engine

import "core:unicode/utf8"

// Particle storage, population construction, and placement publication.

Particle_Id :: distinct int
Visible :: distinct bool
Layer :: distinct int // nonnegative cell-layer index

Particle_Flag :: enum {
	Visible,
	Fill,
	Update_Queued,
	Preserve_Initial_Colors,
}
Particle_Flags :: bit_set[Particle_Flag;u8]

// Alignment groups: eight-byte geometry, four-byte IDs/glyphs, then byte data.
// The SoA stores one column per field; the four booleans share one byte column.
Particle :: struct {
	initial_coord:         Coord,
	current_coord:         Coord,
	layer:                 int,
	initial_appearance_id: Appearance_Id,
	shared_appearance_id:  Appearance_Id, // zero selects private_appearance
	initial_symbol:        rune,
	symbol:                rune,
	private_appearance:    Appearance,
	flags:                 Particle_Flags,
}

Particle_Storage :: #soa[dynamic]Particle

Particle_Kind :: enum {
	Input,
	Inner_Fill,
	Outer_Fill,
}

Particle_Sets :: struct {
	input:      [dynamic]Particle_Id,
	inner_fill: [dynamic]Particle_Id,
	outer_fill: [dynamic]Particle_Id,
}

init_particle :: proc(
	e: ^Engine,
	id: Particle_Id,
	symbol: rune,
	shared_id: Appearance_Id,
	position: Coord,
) {
	assert(shared_id != NO_APPEARANCE && int(shared_id) <= len(e.shared_appearances))
	assert(utf8.valid_rune(symbol), "symbol must be a valid Unicode scalar value")
	e.particles[id].initial_coord = position
	e.particles[id].current_coord = position
	e.particles[id].initial_symbol = symbol
	e.particles[id].symbol = symbol
	e.particles[id].initial_appearance_id = shared_id
	e.particles[id].shared_appearance_id = shared_id
	// New particles have no published membership; later edits use this entry.
	append(&e.updates, Particle_Update{id = id, previous_cell = -1})
	e.particles[id].flags += {.Update_Queued}
}

make_fill_particles :: proc(e: ^Engine, occupied: []bool) {
	count := 0
	for cell in occupied {
		if !cell do count += 1
	}
	first := len(e.particles)
	resize(&e.particles, first + count)
	if count == 0 do return
	reserve(&e.updates, cap(e.particles))
	blank := prepare_appearance(e, Appearance{})
	written := 0
	for row in 1 ..= e.canvas.top {
		for column in 1 ..= e.canvas.right {
			if occupied[(row - 1) * e.canvas.right + column - 1] do continue
			id := first + written
			e.particles.flags[id] += {.Fill}
			init_particle(e, Particle_Id(id), ' ', blank, coord(column, row))
			written += 1
			if canvas_in_text(e.canvas, coord(column, row)) {
				append(&e.particle_sets.inner_fill, Particle_Id(id))
			} else {
				append(&e.particle_sets.outer_fill, Particle_Id(id))
			}
		}
	}
}

// A build-time batch owns capacity planning. Callers specify the number of
// characters they will create, without reading or sizing engine storage.
Particle_Batch :: struct {
	engine:    ^Engine,
	remaining: int,
}

particle_batch :: proc(e: ^Engine, count: int) -> Particle_Batch {
	assert(count >= 0)
	reserve(&e.particles, len(e.particles) + count)
	reserve(&e.updates, cap(e.particles))
	return {e, count}
}

add_particle :: proc {
	add_particle_single,
	add_particle_batched,
}

@(private = "file")
add_particle_batched :: #force_inline proc(
	batch: ^Particle_Batch,
	symbol: rune,
	shared_id: Appearance_Id,
	position: Coord,
) -> Particle_Id {
	assert(batch.remaining > 0)
	batch.remaining -= 1
	return add_particle_single(batch.engine, symbol, shared_id, position)
}

@(private = "file")
add_particle_single :: proc(
	e: ^Engine,
	symbol: rune,
	shared_id: Appearance_Id,
	position: Coord,
) -> Particle_Id {
	append(&e.particles, Particle{})
	reserve(&e.updates, cap(e.particles))
	id := Particle_Id(len(e.particles) - 1)
	init_particle(e, id, symbol, shared_id, position)
	return id
}

set_symbol :: #force_inline proc(e: ^Engine, id: Particle_Id, value: rune) {
	if e.particles[id].symbol == value do return
	assert(utf8.valid_rune(value), "symbol must be a valid Unicode scalar value")
	queue_particle(e, id)
	e.particles[id].symbol = value
}

set_particle :: proc {
	set_position,
	set_visible,
	set_layer,
	set_placement,
}

set_position :: #force_inline proc(e: ^Engine, id: Particle_Id, value: Coord) {
	old := e.particles[id].current_coord
	if old == value do return
	queue_particle(e, id)
	e.particles[id].current_coord = value
}

set_visible :: #force_inline proc(e: ^Engine, id: Particle_Id, value: Visible) {
	visible := bool(value)
	if (.Visible in e.particles[id].flags) == visible do return
	queue_particle(e, id)
	if visible {e.particles[id].flags += {.Visible}} else {e.particles[id].flags -= {.Visible}}
}

set_layer :: #force_inline proc(e: ^Engine, id: Particle_Id, value: Layer) {
	layer := int(value)
	assert(layer >= 0 && layer < max(int), "layer must be a nonnegative array index")
	old_layer := e.particles[id].layer
	if old_layer == layer do return
	queue_particle(e, id)
	e.particles[id].layer = layer
}

// Apply combined placement changes with one membership removal/insertion.
set_placement :: #force_inline proc(
	e: ^Engine,
	id: Particle_Id,
	coord: Coord,
	visible: bool,
	layer: int,
) {
	assert(layer >= 0 && layer < max(int), "layer must be a nonnegative array index")
	old_coord := e.particles[id].current_coord
	old_visible := (.Visible in e.particles[id].flags)
	old_layer := e.particles[id].layer
	placement_changed := coord != old_coord || visible != old_visible || layer != old_layer
	if !placement_changed do return
	queue_particle(e, id)
	e.particles[id].current_coord = coord
	if visible {e.particles[id].flags += {.Visible}} else {e.particles[id].flags -= {.Visible}}
	e.particles[id].layer = layer
}
