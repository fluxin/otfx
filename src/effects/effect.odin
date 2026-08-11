package effects

import "../engine"

import "core:math/ease"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// Effect states are stored in a discriminated union; operations on them are
// proc groups resolved at compile time. The union switch below forwards to
// the group by the stored tag — no function pointers, no vtables.

Effect_State :: union {
	Slide_State,
	Beams_State,
	Rings_State,
	Waves_State,
	Matrix_State,
	Decrypt_State,
	Rain_State,
	Wipe_State,
	Scattered_State,
	Expand_State,
	Middleout_State,
	Colorshift_State,
	Highlight_State,
	Sweep_State,
	Randomsequence_State,
	Pour_State,
	Bouncyballs_State,
	Spray_State,
	Slice_State,
	Overflow_State,
	Print_State,
	Errorcorrect_State,
	Unstable_State,
	Smoke_State,
	Burn_State,
	Crumble_State,
	Fireworks_State,
	Spotlights_State,
	Vhstape_State,
	Orbittingvolley_State,
	Synthgrid_State,
	Bubbles_State,
	Binarypath_State,
	Swarm_State,
	Laseretch_State,
	Blackhole_State,
	Thunderstorm_State,
}

Effect :: struct {
	state: Effect_State,
}

Effect_Kind :: enum {
	Slide,
	Beams,
	Rings,
	Waves,
	Matrix,
	Decrypt,
	Rain,
	Wipe,
	Scattered,
	Expand,
	Middleout,
	Colorshift,
	Highlight,
	Sweep,
	Randomsequence,
	Pour,
	Bouncyballs,
	Spray,
	Slice,
	Overflow,
	Print,
	Errorcorrect,
	Unstable,
	Smoke,
	Burn,
	Crumble,
	Fireworks,
	Spotlights,
	Vhstape,
	Orbittingvolley,
	Synthgrid,
	Bubbles,
	Binarypath,
	Swarm,
	Laseretch,
	Blackhole,
	Thunderstorm,
}

effect_build :: proc {
	slide_build,
	beams_build,
	rings_build,
	waves_build,
	matrix_build,
	decrypt_build,
	rain_build,
	wipe_build,
	scattered_build,
	expand_build,
	middleout_build,
	colorshift_build,
	highlight_build,
	sweep_build,
	randomsequence_build,
	pour_build,
	bouncyballs_build,
	spray_build,
	slice_build,
	overflow_build,
	print_build,
	errorcorrect_build,
	unstable_build,
	smoke_build,
	burn_build,
	crumble_build,
	fireworks_build,
	spotlights_build,
	vhstape_build,
	orbittingvolley_build,
	synthgrid_build,
	bubbles_build,
	binarypath_build,
	swarm_build,
	laseretch_build,
	blackhole_build,
	thunderstorm_build,
}

effect_next :: proc {
	slide_next,
	beams_next,
	rings_next,
	waves_next,
	matrix_next,
	decrypt_next,
	rain_next,
	wipe_next,
	scattered_next,
	expand_next,
	middleout_next,
	colorshift_next,
	highlight_next,
	sweep_next,
	randomsequence_next,
	pour_next,
	bouncyballs_next,
	spray_next,
	slice_next,
	overflow_next,
	print_next,
	errorcorrect_next,
	unstable_next,
	smoke_next,
	burn_next,
	crumble_next,
	fireworks_next,
	spotlights_next,
	vhstape_next,
	orbittingvolley_next,
	synthgrid_next,
	bubbles_next,
	binarypath_next,
	swarm_next,
	laseretch_next,
	blackhole_next,
	thunderstorm_next,
}

effect_parse :: proc {
	slide_parse,
	beams_parse,
	rings_parse,
	waves_parse,
	matrix_parse,
	decrypt_parse,
	rain_parse,
	wipe_parse,
	scattered_parse,
	expand_parse,
	middleout_parse,
	colorshift_parse,
	highlight_parse,
	sweep_parse,
	randomsequence_parse,
	pour_parse,
	bouncyballs_parse,
	spray_parse,
	slice_parse,
	overflow_parse,
	print_parse,
	errorcorrect_parse,
	unstable_parse,
	smoke_parse,
	burn_parse,
	crumble_parse,
	fireworks_parse,
	spotlights_parse,
	vhstape_parse,
	orbittingvolley_parse,
	synthgrid_parse,
	bubbles_parse,
	binarypath_parse,
	swarm_parse,
	laseretch_parse,
	blackhole_parse,
	thunderstorm_parse,
}

make_effect :: proc(kind: Effect_Kind, args: []string) -> (Effect, bool) {
	switch kind {
	case .Slide:
		cfg := slide_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Slide_State{config = cfg}}, true
	case .Beams:
		cfg := beams_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Beams_State{config = cfg}}, true
	case .Rings:
		cfg := rings_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Rings_State{config = cfg}}, true
	case .Waves:
		cfg := waves_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Waves_State{config = cfg}}, true
	case .Matrix:
		cfg := matrix_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Matrix_State{config = cfg}}, true
	case .Decrypt:
		cfg := decrypt_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Decrypt_State{config = cfg}}, true
	case .Rain:
		cfg := rain_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Rain_State{config = cfg}}, true
	case .Wipe:
		cfg := wipe_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Wipe_State{config = cfg}}, true
	case .Scattered:
		cfg := scattered_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Scattered_State{config = cfg}}, true
	case .Expand:
		cfg := expand_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Expand_State{config = cfg}}, true
	case .Middleout:
		cfg := middleout_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Middleout_State{config = cfg}}, true
	case .Colorshift:
		cfg := colorshift_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Colorshift_State{config = cfg}}, true
	case .Highlight:
		cfg := highlight_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Highlight_State{config = cfg}}, true
	case .Sweep:
		cfg := sweep_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Sweep_State{config = cfg}}, true
	case .Randomsequence:
		cfg := randomsequence_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Randomsequence_State{config = cfg}}, true
	case .Pour:
		cfg := pour_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Pour_State{config = cfg}}, true
	case .Bouncyballs:
		cfg := bouncyballs_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Bouncyballs_State{config = cfg}}, true
	case .Spray:
		cfg := spray_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Spray_State{config = cfg}}, true
	case .Slice:
		cfg := slice_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Slice_State{config = cfg}}, true
	case .Overflow:
		cfg := overflow_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Overflow_State{config = cfg}}, true
	case .Print:
		cfg := print_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Print_State{config = cfg}}, true
	case .Errorcorrect:
		cfg := errorcorrect_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Errorcorrect_State{config = cfg}}, true
	case .Unstable:
		cfg := unstable_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Unstable_State{config = cfg}}, true
	case .Smoke:
		cfg := smoke_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Smoke_State{config = cfg}}, true
	case .Burn:
		cfg := burn_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Burn_State{config = cfg}}, true
	case .Crumble:
		cfg := crumble_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Crumble_State{config = cfg}}, true
	case .Fireworks:
		cfg := fireworks_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Fireworks_State{config = cfg}}, true
	case .Spotlights:
		cfg := spotlights_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Spotlights_State{config = cfg}}, true
	case .Vhstape:
		cfg := vhstape_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Vhstape_State{config = cfg}}, true
	case .Orbittingvolley:
		cfg := orbittingvolley_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Orbittingvolley_State{config = cfg}}, true
	case .Synthgrid:
		cfg := synthgrid_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Synthgrid_State{config = cfg}}, true
	case .Bubbles:
		cfg := bubbles_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Bubbles_State{config = cfg}}, true
	case .Binarypath:
		cfg := binarypath_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Binarypath_State{config = cfg}}, true
	case .Swarm:
		cfg := swarm_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Swarm_State{config = cfg}}, true
	case .Laseretch:
		cfg := laseretch_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Laseretch_State{config = cfg}}, true
	case .Blackhole:
		cfg := blackhole_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Blackhole_State{config = cfg}}, true
	case .Thunderstorm:
		cfg := thunderstorm_config_default()
		if !effect_parse(&cfg, args) do return {}, false
		return {state = Thunderstorm_State{config = cfg}}, true
	}
	return {}, false
}

// Tagged-union dispatch: each case resolves its call through the proc group.
build_effect :: proc(effect: ^Effect, ctx: ^engine.Engine) {
	switch &s in effect.state {
	case Slide_State:
		effect_build(&s, ctx)
	case Beams_State:
		effect_build(&s, ctx)
	case Rings_State:
		effect_build(&s, ctx)
	case Waves_State:
		effect_build(&s, ctx)
	case Matrix_State:
		effect_build(&s, ctx)
	case Decrypt_State:
		effect_build(&s, ctx)
	case Rain_State:
		effect_build(&s, ctx)
	case Wipe_State:
		effect_build(&s, ctx)
	case Scattered_State:
		effect_build(&s, ctx)
	case Expand_State:
		effect_build(&s, ctx)
	case Middleout_State:
		effect_build(&s, ctx)
	case Colorshift_State:
		effect_build(&s, ctx)
	case Highlight_State:
		effect_build(&s, ctx)
	case Sweep_State:
		effect_build(&s, ctx)
	case Randomsequence_State:
		effect_build(&s, ctx)
	case Pour_State:
		effect_build(&s, ctx)
	case Bouncyballs_State:
		effect_build(&s, ctx)
	case Spray_State:
		effect_build(&s, ctx)
	case Slice_State:
		effect_build(&s, ctx)
	case Overflow_State:
		effect_build(&s, ctx)
	case Print_State:
		effect_build(&s, ctx)
	case Errorcorrect_State:
		effect_build(&s, ctx)
	case Unstable_State:
		effect_build(&s, ctx)
	case Smoke_State:
		effect_build(&s, ctx)
	case Burn_State:
		effect_build(&s, ctx)
	case Crumble_State:
		effect_build(&s, ctx)
	case Fireworks_State:
		effect_build(&s, ctx)
	case Spotlights_State:
		effect_build(&s, ctx)
	case Vhstape_State:
		effect_build(&s, ctx)
	case Orbittingvolley_State:
		effect_build(&s, ctx)
	case Synthgrid_State:
		effect_build(&s, ctx)
	case Bubbles_State:
		effect_build(&s, ctx)
	case Binarypath_State:
		effect_build(&s, ctx)
	case Swarm_State:
		effect_build(&s, ctx)
	case Laseretch_State:
		effect_build(&s, ctx)
	case Blackhole_State:
		effect_build(&s, ctx)
	case Thunderstorm_State:
		effect_build(&s, ctx)
	case:
		unreachable()
	}
}

next_frame :: proc(effect: ^Effect, ctx: ^engine.Engine) -> ([]engine.Char_Id, bool) {
	switch &s in effect.state {
	case Slide_State:
		return effect_next(&s, ctx)
	case Beams_State:
		return effect_next(&s, ctx)
	case Rings_State:
		return effect_next(&s, ctx)
	case Waves_State:
		return effect_next(&s, ctx)
	case Matrix_State:
		return effect_next(&s, ctx)
	case Decrypt_State:
		return effect_next(&s, ctx)
	case Rain_State:
		return effect_next(&s, ctx)
	case Wipe_State:
		return effect_next(&s, ctx)
	case Scattered_State:
		return effect_next(&s, ctx)
	case Expand_State:
		return effect_next(&s, ctx)
	case Middleout_State:
		return effect_next(&s, ctx)
	case Colorshift_State:
		return effect_next(&s, ctx)
	case Highlight_State:
		return effect_next(&s, ctx)
	case Sweep_State:
		return effect_next(&s, ctx)
	case Randomsequence_State:
		return effect_next(&s, ctx)
	case Pour_State:
		return effect_next(&s, ctx)
	case Bouncyballs_State:
		return effect_next(&s, ctx)
	case Spray_State:
		return effect_next(&s, ctx)
	case Slice_State:
		return effect_next(&s, ctx)
	case Overflow_State:
		return effect_next(&s, ctx)
	case Print_State:
		return effect_next(&s, ctx)
	case Errorcorrect_State:
		return effect_next(&s, ctx)
	case Unstable_State:
		return effect_next(&s, ctx)
	case Smoke_State:
		return effect_next(&s, ctx)
	case Burn_State:
		return effect_next(&s, ctx)
	case Crumble_State:
		return effect_next(&s, ctx)
	case Fireworks_State:
		return effect_next(&s, ctx)
	case Spotlights_State:
		return effect_next(&s, ctx)
	case Vhstape_State:
		return effect_next(&s, ctx)
	case Orbittingvolley_State:
		return effect_next(&s, ctx)
	case Synthgrid_State:
		return effect_next(&s, ctx)
	case Bubbles_State:
		return effect_next(&s, ctx)
	case Binarypath_State:
		return effect_next(&s, ctx)
	case Swarm_State:
		return effect_next(&s, ctx)
	case Laseretch_State:
		return effect_next(&s, ctx)
	case Blackhole_State:
		return effect_next(&s, ctx)
	case Thunderstorm_State:
		return effect_next(&s, ctx)
	case:
		return nil, false
	}
}

Run_Outcome :: enum {
	Complete,
	Terminal_Resized,
}

// A resize never mutates an in-flight effect. Its geometry, fills, and all
// source-indexed effect columns were built for the old canvas, so the caller
// rebuilds a fresh engine/effect after this returns .Terminal_Resized.
run_effect :: proc(effect: ^Effect, ctx: ^engine.Engine, resize_aware: bool) -> Run_Outcome {
	build_effect(effect, ctx)
	free_all(context.temp_allocator)
	engine.prep_canvas(ctx.cfg.reuse_canvas, ctx.move_to_top, ctx.visible_right, ctx.visible_top)
	frames := 0
	for ctx.cfg.max_frames == nil || frames < ctx.cfg.max_frames.? {
		if resize_aware && engine.resize_settled(ctx) {
			engine.reset_canvas_area(ctx.visible_top)
			return .Terminal_Resized
		}
		render_candidates, produced := next_frame(effect, ctx)
		if !produced do break
		if render_candidates == nil {
			engine.frame_all(ctx)
		} else {
			engine.frame(ctx, render_candidates)
		}
		if resize_aware && engine.resize_settled(ctx) {
			engine.reset_canvas_area(ctx.visible_top)
			return .Terminal_Resized
		}
		engine.print_frame(ctx.move_to_top, ctx.out_buf[:])
		frames += 1
	}
	engine.restore_cursor(ctx.cfg.no_restore_cursor, ctx.cfg.no_eol)
	return .Complete
}

Float_Range_Value :: struct {
	lo, hi: f64,
}
Int_Range_Value :: struct {
	lo, hi: int,
}

// ---------------------------------------------------------------------------
// shared helpers
// ---------------------------------------------------------------------------

// "--name=value" splitting.
split_opt :: proc(arg: string) -> (name, value: string, has_value: bool) {
	if eq := strings.index(arg, "="); eq >= 0 do return arg[:eq], arg[eq + 1:], true
	return arg, "", false
}

// Consume the value for a flag (either --name=value or the next argument).
opt_value :: proc(args: []string, i: ^int, value: string, has_value: bool) -> (string, bool) {
	if has_value do return value, true
	if i^ + 1 < len(args) {
		i^ += 1
		return args[i^], true
	}
	return "", false
}

parse_int_flag :: proc(
	ptr: ^int,
	args: []string,
	i: ^int,
	value: string,
	has_value: bool,
) -> bool {
	v, ok := opt_value(args, i, value, has_value)
	if !ok do return false
	n, ok2 := strconv.parse_int(v)
	if !ok2 do return false
	ptr^ = int(n)
	return true
}

parse_float_flag :: proc(
	ptr: ^f64,
	args: []string,
	i: ^int,
	value: string,
	has_value: bool,
) -> bool {
	v, ok := opt_value(args, i, value, has_value)
	if !ok do return false
	f, ok2 := strconv.parse_f64(v)
	if !ok2 do return false
	ptr^ = f
	return true
}

parse_color_flag :: proc(
	ptr: ^engine.Color,
	args: []string,
	i: ^int,
	value: string,
	has_value: bool,
) -> bool {
	v, ok := opt_value(args, i, value, has_value)
	if !ok do return false
	c, ok2 := engine.parse_cli_color(v)
	if !ok2 do return false
	ptr^ = c
	return true
}

parse_colors_flag :: proc(
	list: ^[dynamic]engine.Color,
	args: []string,
	i: ^int,
	value: string,
	has_value: bool,
) -> bool {
	v, ok := opt_value(args, i, value, has_value)
	if !ok do return false
	clear(list)
	for field in strings.split(v, " ") {
		c, ok2 := engine.parse_cli_color(field)
		if !ok2 do return false
		append(list, c)
	}
	return true
}

parse_ints_flag :: proc(
	list: ^[dynamic]int,
	args: []string,
	i: ^int,
	value: string,
	has_value: bool,
) -> bool {
	v, ok := opt_value(args, i, value, has_value)
	if !ok do return false
	clear(list)
	for field in strings.split(v, " ") {
		n, ok2 := strconv.parse_int(field)
		if !ok2 do return false
		append(list, int(n))
	}
	return true
}

parse_ease_flag :: proc(
	ptr: ^ease.Ease,
	args: []string,
	i: ^int,
	value: string,
	has_value: bool,
) -> bool {
	v, ok := opt_value(args, i, value, has_value)
	if !ok do return false
	en, ok2 := engine.easing_parse(v)
	if !ok2 do return false
	ptr^ = en
	return true
}

parse_gdir_flag :: proc(
	ptr: ^engine.Gradient_Direction,
	args: []string,
	i: ^int,
	value: string,
	has_value: bool,
) -> bool {
	v, ok := opt_value(args, i, value, has_value)
	if !ok do return false
	d, ok2 := engine.gdir_parse(v)
	if !ok2 do return false
	ptr^ = d
	return true
}

parse_group_flag :: proc(
	ptr: ^engine.Character_Group,
	args: []string,
	i: ^int,
	value: string,
	has_value: bool,
) -> bool {
	v, ok := opt_value(args, i, value, has_value)
	if !ok do return false
	g, ok2 := engine.group_parse(v)
	if !ok2 do return false
	ptr^ = g
	return true
}

parse_symbol_flag :: proc(
	ptr: ^string,
	args: []string,
	i: ^int,
	value: string,
	has_value: bool,
) -> bool {
	v, ok := opt_value(args, i, value, has_value)
	if !ok do return false
	_, rune_bytes := utf8.decode_rune(v)
	if rune_bytes == 0 || rune_bytes != len(v) do return false
	ptr^ = v
	return true
}

parse_symbols_flag :: proc(
	list: ^[dynamic]string,
	args: []string,
	i: ^int,
	value: string,
	has_value: bool,
) -> bool {
	v, ok := opt_value(args, i, value, has_value)
	if !ok do return false
	clear(list)
	for field in strings.split(v, " ") {
		_, rune_bytes := utf8.decode_rune(field)
		if rune_bytes == 0 || rune_bytes != len(field) do return false
		append(list, field)
	}
	return true
}

parse_float_range_flag :: proc(
	ptr: ^Float_Range_Value,
	args: []string,
	i: ^int,
	value: string,
	has_value: bool,
) -> bool {
	v, ok := opt_value(args, i, value, has_value)
	if !ok do return false
	lo_s, hi_s, ok2 := split_range(v)
	if !ok2 do return false
	lo, lok := strconv.parse_f64(lo_s)
	hi, hok := strconv.parse_f64(hi_s)
	if !lok || !hok || lo <= 0 || lo > hi do return false
	ptr^ = {lo, hi}
	return true
}

parse_int_range_flag :: proc(
	ptr: ^Int_Range_Value,
	args: []string,
	i: ^int,
	value: string,
	has_value: bool,
) -> bool {
	v, ok := opt_value(args, i, value, has_value)
	if !ok do return false
	lo_s, hi_s, ok2 := split_range(v)
	if !ok2 do return false
	lo, lok := strconv.parse_int(lo_s)
	hi, hok := strconv.parse_int(hi_s)
	if !lok || !hok || lo <= 0 || lo > hi do return false
	ptr^ = {int(lo), int(hi)}
	return true
}

// "lo-hi" range splitter.
split_range :: proc(s: string) -> (lo, hi: string, ok: bool) {
	idx := strings.index(s, "-")
	if idx < 0 do return
	return s[:idx], s[idx + 1:], true
}
