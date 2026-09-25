package regression

import "../src/engine"
import "base:intrinsics"
import "core:container/bit_array"
import "core:mem"
import "core:strings"
import "core:testing"

// Independent full-paint oracle: no retained membership or dirty state.
raster_expected :: proc(e: ^engine.Engine, selected: []engine.Char_Id, all: bool, out: []i32) {
	for &cell in out do cell = -1
	for id in 0 ..< len(e.chars) {
		included := all
		for candidate in selected do included ||= int(candidate) == id
		if !included || !e.chars.is_visible[id] do continue
		p := e.chars.current_coord[id]
		row, column := p.row + e.layout.row_offset, p.column + e.layout.col_offset
		if row < e.layout.visible_bottom ||
		   row > e.layout.visible_top ||
		   column < e.layout.visible_left ||
		   column > e.layout.visible_right {
			continue
		}
		cell := &out[(row - 1) * e.layout.visible_right + column - 1]
		if cell^ < 0 ||
		   e.chars.layer[id] > e.chars.layer[cell^] ||
		   (e.chars.layer[id] == e.chars.layer[cell^] && id > int(cell^)) {
			cell^ = i32(id)
		}
	}
}

@(test)
retained_raster_matches_full_paint :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	// Exercise bitmap tails and rows sharing a word, plus character growth
	// across membership words. Overlaps include different and equal layers.
	for width in ([]int{1, 7, 63, 64, 65}) {
		cfg := engine.config_default()
		cfg.canvas_width, cfg.canvas_height = width, 3
		cfg.ignore_terminal_dimensions = true
		e, err := engine.engine_make("ABC\nD", cfg, context.allocator)
		testing.expect_value(t, err, engine.Input_Error.None)
		expected := make([]i32, width * 3)
		selected: [dynamic]engine.Char_Id
		for tick in 0 ..< 90 {
			if tick == 30 || tick == 60 {
				for _ in 0 ..< 65 do engine.add_character(&e, "X", {1, 1})
			}
			clear(&selected)
			for id in 0 ..< len(e.chars) {
				engine.mark_character_dirty(&e, engine.Char_Id(id))
				e.chars.is_visible[id] = (id + tick) % 5 != 0
				e.chars.layer[id] = (id + tick / 3) % 4 - 2
				// Include clipping and crowded cells; leave positions unchanged
				// on alternate ticks to exercise independent layer/visual changes.
				e.chars.current_coord[id] = {
					(id * 7 + tick / 2) % (width + 2),
					(id + tick / 4) % 5,
				}
				engine.set_symbol(&e, engine.Char_Id(id), "X" if (id + tick) % 2 == 0 else "Y")
				engine.set_foreground(&e, engine.Char_Id(id), engine.Color{u8(tick), 100, 200})
				if tick % 7 != 0 && (id + tick) % 3 != 0 {
					append(&selected, engine.Char_Id(id))
					if id % 11 == 0 do append(&selected, engine.Char_Id(id))
				}
			}
			all := tick % 4 == 0
			raster_expected(&e, selected[:], all, expected)
			if all {
				engine.update_render_cells_all(&e)
				engine.frame_build_all(&e)
			} else {
				engine.update_render_cells_selected(&e, selected[:])
				engine.frame_build_selected(&e, selected[:])
			}
			for cell, index in expected do testing.expect_value(t, e.render_cells[index], cell)
			for word in e.dirty_cells.bits do testing.expect_value(t, word, u64(0))
			// No changes: no output, regardless of overlaps or selection order.
			if all {engine.frame_build_all(&e)} else {engine.frame_build_selected(&e, selected[:])}
			testing.expect_value(t, len(e.out_buf), 0)
		}
	}
}

@(test)
retained_raster_keeps_pending_visual_changes :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 65, 2
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("A", cfg, context.allocator)
	testing.expect_value(t, err, engine.Input_Error.None)
	id := e.character_sets.input[0]
	e.chars.is_visible[id] = true
	e.chars.current_coord[id] = {65, 2}
	engine.frame_build_all(&e)
	testing.expect_value(t, string(e.out_buf[:]), "\x1b[64CA")
	// Update without emission, then move again. Only the latest position is
	// drawn, but the last emitted position must still be erased.
	e.chars.current_coord[id] = {1, 1}
	engine.mark_character_dirty(&e, id)
	engine.update_render_cells_all(&e)
	e.chars.current_coord[id] = {2, 1}
	engine.set_symbol(&e, engine.Char_Id(id), "B")
	engine.mark_character_dirty(&e, id)
	engine.frame_build_all(&e)
	testing.expect_value(t, string(e.out_buf[:]), "\x1b[64C \x1b[1E\x1b[1CB")
	engine.frame_build_all(&e)
	testing.expect_value(t, len(e.out_buf), 0)
}

@(test)
character_settings_deduplicate_changes :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 3, 1
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("A", cfg, context.allocator)
	testing.expect_value(t, err, engine.Input_Error.None)
	id := e.character_sets.input[0]
	engine.set_character(&e, id, visible = true)
	engine.frame_build_all(&e)
	visual := engine.get_visual(&e, engine.Char_Id(id))
	// Equal text from a distinct allocation is still an unchanged setting.
	visual.symbol = strings.clone(visual.symbol)
	engine.set_character(&e, id)
	engine.set_character(
		&e,
		id,
		coord = e.chars.current_coord[id],
		visible = true,
		layer = 0,
		visual = visual,
	)
	testing.expect_value(t, dirty_character_count(&e), 0)
	// Separate lanes share one queued entry. Omitted settings remain intact.
	engine.set_character(&e, id, coord = engine.Coord{2, 1})
	engine.set_character(&e, id, layer = 5)
	visual.symbol = "B"
	visual.fg = engine.Color{1, 2, 3}
	engine.set_character(&e, id, visual = visual)
	testing.expect_value(t, dirty_character_count(&e), 1)
	testing.expect_value(t, e.chars.layer[id], 5)
	testing.expect_value(t, e.chars.is_visible[id], true)
	engine.frame_build_all(&e)
	testing.expect_value(t, e.render_cells[0], i32(-1))
	testing.expect_value(t, e.render_cells[1], i32(id))
	// Clearing a nullable color is an actual visual update. Appearance-only
	// changes mark the winning cell directly instead of queueing membership.
	visual.fg = nil
	engine.set_character(&e, id, visual = visual)
	testing.expect_value(t, dirty_character_count(&e), 0)
	testing.expect(t, bit_array.get(&e.dirty_cells, 1))
	engine.frame_build_all(&e)
	testing.expect(t, len(e.out_buf) > 0)
	engine.set_character(&e, id, visible = false)
	testing.expect_value(t, dirty_character_count(&e), 1)
	engine.frame_build_all(&e)
	testing.expect_value(t, e.render_cells[1], i32(-1))
}

@(test)
retained_raster_reveals_occluded_visual_changes :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 1, 1
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("A", cfg, context.allocator)
	testing.expect_value(t, err, engine.Input_Error.None)
	back := e.character_sets.input[0]
	front := engine.add_character(&e, "B", {1, 1})
	engine.set_character(&e, back, visible = true)
	engine.set_character(&e, front, visible = true, layer = 1)
	engine.frame_build_all(&e)
	testing.expect_value(t, string(e.out_buf[:]), "B")
	visual := engine.get_visual(&e, engine.Char_Id(back))
	visual.symbol = "Z"
	engine.set_character(&e, back, visual = visual)
	engine.frame_build_all(&e)
	testing.expect_value(t, len(e.out_buf), 0)
	engine.set_character(&e, front, visible = false)
	engine.frame_build_all(&e)
	testing.expect_value(t, string(e.out_buf[:]), "Z")
	// A visual-only tag followed by selection admission must synchronize
	// membership even though the generation already contains that character.
	engine.frame_build_selected(&e, []engine.Char_Id{front})
	visual.symbol = "Y"
	engine.set_character(&e, back, visual = visual)
	engine.frame_build_all(&e)
	testing.expect_value(t, string(e.out_buf[:]), "Y")
}

@(test)
retained_raster_character_growth_is_amortized :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, mem.dynamic_arena_allocator(&arena))
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	cfg := engine.config_default()
	cfg.canvas_width, cfg.canvas_height = 1, 1
	cfg.ignore_terminal_dimensions = true
	e, err := engine.engine_make("A", cfg, context.allocator)
	testing.expect_value(t, err, engine.Input_Error.None)
	allocations := track.total_allocation_count
	for _ in 0 ..< 8192 do engine.add_character(&e, "X", {1, 1})
	// Exact-capacity reservation per added character caused quadratic arena
	// growth. Thousands of additions should need only geometric pool growth.
	testing.expect(t, track.total_allocation_count - allocations < 200)
	testing.expect_value(t, dirty_character_count(&e), len(e.chars))
	engine.frame_build_all(&e)
	allocations = track.total_allocation_count
	for id in 0 ..< len(e.chars) {
		engine.set_character(&e, engine.Char_Id(id), visible = true)
	}
	engine.frame_build_all(&e)
	testing.expect_value(t, track.total_allocation_count, allocations)
}

dirty_character_count :: proc(e: ^engine.Engine) -> int {
	count := 0
	for word in e.dirty_characters.bits do count += int(intrinsics.count_ones(word))
	return count
}
