package common

import "../../src/effects"
import "../../src/engine"

import "core:math/rand"
import "core:reflect"
import "core:strings"

// Shared by the tools that drive the engine directly instead of shelling out to
// the CLI: the documentation renderer and the parity capture. Both need the same
// three things -- resolve an effect name, build a seeded run, step it a frame at
// a time -- and neither belongs in the shipping binary.

Run :: struct {
	engine_state: engine.Engine,
	effect:       effects.Effect,
}

// The CLI's effect names are the enum names lowercased, so the enum stays the
// single source of truth and a new effect needs no table update here.
effect_name :: proc(kind: effects.Effect_Kind, allocator := context.allocator) -> string {
	name, _ := reflect.enum_name_from_value(kind)
	return strings.to_lower(name, allocator)
}

effect_kind_from_name :: proc(name: string) -> (effects.Effect_Kind, bool) {
	for candidate in effects.Effect_Kind {
		found := effect_name(candidate, context.temp_allocator)
		if found == name do return candidate, true
	}
	return {}, false
}

// Reseeding before the engine is built is what makes a run reproducible, and it
// is why a caller can replay the same run twice and get the same frames.
run_make :: proc(
	kind: effects.Effect_Kind,
	args: []string,
	cfg: engine.Terminal_Config,
	input: string,
	seed: u64,
) -> (
	run: Run,
	ok: bool,
) {
	rand.reset_u64(seed)
	message: string
	engine_ok: bool
	run.engine_state, message, engine_ok = engine.engine_make(input, cfg, context.allocator)
	if !engine_ok do return {}, false
	effect_ok: bool
	run.effect, effect_ok = effects.make_effect(kind, args)
	if !effect_ok do return {}, false
	effects.build_effect(&run.effect, &run.engine_state)
	free_all(context.temp_allocator)
	return run, true
}

// Reports the rendered grid extent alongside liveness, so a caller can read the
// cell grid without recomputing the canvas size.
run_step :: proc(run: ^Run) -> (width, height: int, ok: bool) {
	render_candidates, produced := effects.next_frame(&run.effect, &run.engine_state)
	if !produced do return 0, 0, false
	if render_candidates == nil {
		width, height = engine.update_render_cells_all(&run.engine_state)
	} else {
		width, height = engine.update_render_cells_selected(&run.engine_state, render_candidates)
	}
	return width, height, true
}
