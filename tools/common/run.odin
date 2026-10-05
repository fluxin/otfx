package common

import "../../src/effects"
import "../../src/engine"

// Shared by the tools that drive the engine directly instead of shelling out to
// the CLI: the documentation renderer and the parity capture. Both need the same
// three things -- resolve an effect name, build a seeded run, step it a frame at
// a time -- and neither belongs in the shipping binary.

Run :: struct {
	engine_state: engine.Engine,
	effect:       effects.Effect,
}

effect_name :: #force_inline proc(kind: effects.Effect_Kind) -> string {
	return effects.effect_name(kind)
}

effect_kind_from_name :: proc(name: string) -> (effects.Effect_Kind, bool) {
	return effects.effect_kind_parse(name)
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
	engine.random_seed(seed)
	input_error: engine.Input_Error
	run.engine_state, input_error = engine.engine_make(input, cfg)
	if input_error != .None do return {}, false
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
	produced := effects.next_frame(&run.effect, &run.engine_state)
	if !produced do return 0, 0, false
	engine.compose_frame(&run.engine_state)
	width = max(run.engine_state.layout.visible_right, 0)
	height = len(run.engine_state.rows)
	return width, height, true
}
