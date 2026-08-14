package effects

import "../engine"

import "core:math/ease"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// Effect states are stored in a discriminated union. The build and frame
// switches below call each concrete state procedure directly.

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

make_effect :: proc(kind: Effect_Kind, args: []string) -> (Effect, bool) {
	switch kind {
	case .Slide:
		cfg := slide_config_default()
		if !slide_parse(&cfg, args) do return {}, false
		return {state = Slide_State{config = cfg}}, true
	case .Beams:
		cfg := beams_config_default()
		if !beams_parse(&cfg, args) do return {}, false
		return {state = Beams_State{config = cfg}}, true
	case .Rings:
		cfg := rings_config_default()
		if !rings_parse(&cfg, args) do return {}, false
		return {state = Rings_State{config = cfg}}, true
	case .Waves:
		cfg := waves_config_default()
		if !waves_parse(&cfg, args) do return {}, false
		return {state = Waves_State{config = cfg}}, true
	case .Matrix:
		cfg := matrix_config_default()
		if !matrix_parse(&cfg, args) do return {}, false
		return {state = Matrix_State{config = cfg}}, true
	case .Decrypt:
		cfg := decrypt_config_default()
		if !decrypt_parse(&cfg, args) do return {}, false
		return {state = Decrypt_State{config = cfg}}, true
	case .Rain:
		cfg := rain_config_default()
		if !rain_parse(&cfg, args) do return {}, false
		return {state = Rain_State{config = cfg}}, true
	case .Wipe:
		cfg := wipe_config_default()
		if !wipe_parse(&cfg, args) do return {}, false
		return {state = Wipe_State{config = cfg}}, true
	case .Scattered:
		cfg := scattered_config_default()
		if !scattered_parse(&cfg, args) do return {}, false
		return {state = Scattered_State{config = cfg}}, true
	case .Expand:
		cfg := expand_config_default()
		if !expand_parse(&cfg, args) do return {}, false
		return {state = Expand_State{config = cfg}}, true
	case .Middleout:
		cfg := middleout_config_default()
		if !middleout_parse(&cfg, args) do return {}, false
		return {state = Middleout_State{config = cfg}}, true
	case .Colorshift:
		cfg := colorshift_config_default()
		if !colorshift_parse(&cfg, args) do return {}, false
		return {state = Colorshift_State{config = cfg}}, true
	case .Highlight:
		cfg := highlight_config_default()
		if !highlight_parse(&cfg, args) do return {}, false
		return {state = Highlight_State{config = cfg}}, true
	case .Sweep:
		cfg := sweep_config_default()
		if !sweep_parse(&cfg, args) do return {}, false
		return {state = Sweep_State{config = cfg}}, true
	case .Randomsequence:
		cfg := randomsequence_config_default()
		if !randomsequence_parse(&cfg, args) do return {}, false
		return {state = Randomsequence_State{config = cfg}}, true
	case .Pour:
		cfg := pour_config_default()
		if !pour_parse(&cfg, args) do return {}, false
		return {state = Pour_State{config = cfg}}, true
	case .Bouncyballs:
		cfg := bouncyballs_config_default()
		if !bouncyballs_parse(&cfg, args) do return {}, false
		return {state = Bouncyballs_State{config = cfg}}, true
	case .Spray:
		cfg := spray_config_default()
		if !spray_parse(&cfg, args) do return {}, false
		return {state = Spray_State{config = cfg}}, true
	case .Slice:
		cfg := slice_config_default()
		if !slice_parse(&cfg, args) do return {}, false
		return {state = Slice_State{config = cfg}}, true
	case .Overflow:
		cfg := overflow_config_default()
		if !overflow_parse(&cfg, args) do return {}, false
		return {state = Overflow_State{config = cfg}}, true
	case .Print:
		cfg := print_config_default()
		if !print_parse(&cfg, args) do return {}, false
		return {state = Print_State{config = cfg}}, true
	case .Errorcorrect:
		cfg := errorcorrect_config_default()
		if !errorcorrect_parse(&cfg, args) do return {}, false
		return {state = Errorcorrect_State{config = cfg}}, true
	case .Unstable:
		cfg := unstable_config_default()
		if !unstable_parse(&cfg, args) do return {}, false
		return {state = Unstable_State{config = cfg}}, true
	case .Smoke:
		cfg := smoke_config_default()
		if !smoke_parse(&cfg, args) do return {}, false
		return {state = Smoke_State{config = cfg}}, true
	case .Burn:
		cfg := burn_config_default()
		if !burn_parse(&cfg, args) do return {}, false
		return {state = Burn_State{config = cfg}}, true
	case .Crumble:
		cfg := crumble_config_default()
		if !crumble_parse(&cfg, args) do return {}, false
		return {state = Crumble_State{config = cfg}}, true
	case .Fireworks:
		cfg := fireworks_config_default()
		if !fireworks_parse(&cfg, args) do return {}, false
		return {state = Fireworks_State{config = cfg}}, true
	case .Spotlights:
		cfg := spotlights_config_default()
		if !spotlights_parse(&cfg, args) do return {}, false
		return {state = Spotlights_State{config = cfg}}, true
	case .Vhstape:
		cfg := vhstape_config_default()
		if !vhstape_parse(&cfg, args) do return {}, false
		return {state = Vhstape_State{config = cfg}}, true
	case .Orbittingvolley:
		cfg := orbittingvolley_config_default()
		if !orbittingvolley_parse(&cfg, args) do return {}, false
		return {state = Orbittingvolley_State{config = cfg}}, true
	case .Synthgrid:
		cfg := synthgrid_config_default()
		if !synthgrid_parse(&cfg, args) do return {}, false
		return {state = Synthgrid_State{config = cfg}}, true
	case .Bubbles:
		cfg := bubbles_config_default()
		if !bubbles_parse(&cfg, args) do return {}, false
		return {state = Bubbles_State{config = cfg}}, true
	case .Binarypath:
		cfg := binarypath_config_default()
		if !binarypath_parse(&cfg, args) do return {}, false
		return {state = Binarypath_State{config = cfg}}, true
	case .Swarm:
		cfg := swarm_config_default()
		if !swarm_parse(&cfg, args) do return {}, false
		return {state = Swarm_State{config = cfg}}, true
	case .Laseretch:
		cfg := laseretch_config_default()
		if !laseretch_parse(&cfg, args) do return {}, false
		return {state = Laseretch_State{config = cfg}}, true
	case .Blackhole:
		cfg := blackhole_config_default()
		if !blackhole_parse(&cfg, args) do return {}, false
		return {state = Blackhole_State{config = cfg}}, true
	case .Thunderstorm:
		cfg := thunderstorm_config_default()
		if !thunderstorm_parse(&cfg, args) do return {}, false
		return {state = Thunderstorm_State{config = cfg}}, true
	}
	return {}, false
}

// Tagged-union dispatch keeps the dynamic branch explicit at the effect boundary.
build_effect :: proc(effect: ^Effect, ctx: ^engine.Engine) {
	switch &s in effect.state {
	case Slide_State:
		slide_build(&s, ctx)
	case Beams_State:
		beams_build(&s, ctx)
	case Rings_State:
		rings_build(&s, ctx)
	case Waves_State:
		waves_build(&s, ctx)
	case Matrix_State:
		matrix_build(&s, ctx)
	case Decrypt_State:
		decrypt_build(&s, ctx)
	case Rain_State:
		rain_build(&s, ctx)
	case Wipe_State:
		wipe_build(&s, ctx)
	case Scattered_State:
		scattered_build(&s, ctx)
	case Expand_State:
		expand_build(&s, ctx)
	case Middleout_State:
		middleout_build(&s, ctx)
	case Colorshift_State:
		colorshift_build(&s, ctx)
	case Highlight_State:
		highlight_build(&s, ctx)
	case Sweep_State:
		sweep_build(&s, ctx)
	case Randomsequence_State:
		randomsequence_build(&s, ctx)
	case Pour_State:
		pour_build(&s, ctx)
	case Bouncyballs_State:
		bouncyballs_build(&s, ctx)
	case Spray_State:
		spray_build(&s, ctx)
	case Slice_State:
		slice_build(&s, ctx)
	case Overflow_State:
		overflow_build(&s, ctx)
	case Print_State:
		print_build(&s, ctx)
	case Errorcorrect_State:
		errorcorrect_build(&s, ctx)
	case Unstable_State:
		unstable_build(&s, ctx)
	case Smoke_State:
		smoke_build(&s, ctx)
	case Burn_State:
		burn_build(&s, ctx)
	case Crumble_State:
		crumble_build(&s, ctx)
	case Fireworks_State:
		fireworks_build(&s, ctx)
	case Spotlights_State:
		spotlights_build(&s, ctx)
	case Vhstape_State:
		vhstape_build(&s, ctx)
	case Orbittingvolley_State:
		orbittingvolley_build(&s, ctx)
	case Synthgrid_State:
		synthgrid_build(&s, ctx)
	case Bubbles_State:
		bubbles_build(&s, ctx)
	case Binarypath_State:
		binarypath_build(&s, ctx)
	case Swarm_State:
		swarm_build(&s, ctx)
	case Laseretch_State:
		laseretch_build(&s, ctx)
	case Blackhole_State:
		blackhole_build(&s, ctx)
	case Thunderstorm_State:
		thunderstorm_build(&s, ctx)
	case:
		unreachable()
	}
}

next_frame :: proc(effect: ^Effect, ctx: ^engine.Engine) -> ([]engine.Char_Id, bool) {
	engine.clock_advance(ctx)
	switch &s in effect.state {
	case Slide_State:
		return slide_next(&s, ctx)
	case Beams_State:
		return beams_next(&s, ctx)
	case Rings_State:
		return rings_next(&s, ctx)
	case Waves_State:
		return waves_next(&s, ctx)
	case Matrix_State:
		return matrix_next(&s, ctx)
	case Decrypt_State:
		return decrypt_next(&s, ctx)
	case Rain_State:
		return rain_next(&s, ctx)
	case Wipe_State:
		return wipe_next(&s, ctx)
	case Scattered_State:
		return scattered_next(&s, ctx)
	case Expand_State:
		return expand_next(&s, ctx)
	case Middleout_State:
		return middleout_next(&s, ctx)
	case Colorshift_State:
		return colorshift_next(&s, ctx)
	case Highlight_State:
		return highlight_next(&s, ctx)
	case Sweep_State:
		return sweep_next(&s, ctx)
	case Randomsequence_State:
		return randomsequence_next(&s, ctx)
	case Pour_State:
		return pour_next(&s, ctx)
	case Bouncyballs_State:
		return bouncyballs_next(&s, ctx)
	case Spray_State:
		return spray_next(&s, ctx)
	case Slice_State:
		return slice_next(&s, ctx)
	case Overflow_State:
		return overflow_next(&s, ctx)
	case Print_State:
		return print_next(&s, ctx)
	case Errorcorrect_State:
		return errorcorrect_next(&s, ctx)
	case Unstable_State:
		return unstable_next(&s, ctx)
	case Smoke_State:
		return smoke_next(&s, ctx)
	case Burn_State:
		return burn_next(&s, ctx)
	case Crumble_State:
		return crumble_next(&s, ctx)
	case Fireworks_State:
		return fireworks_next(&s, ctx)
	case Spotlights_State:
		return spotlights_next(&s, ctx)
	case Vhstape_State:
		return vhstape_next(&s, ctx)
	case Orbittingvolley_State:
		return orbittingvolley_next(&s, ctx)
	case Synthgrid_State:
		return synthgrid_next(&s, ctx)
	case Bubbles_State:
		return bubbles_next(&s, ctx)
	case Binarypath_State:
		return binarypath_next(&s, ctx)
	case Swarm_State:
		return swarm_next(&s, ctx)
	case Laseretch_State:
		return laseretch_next(&s, ctx)
	case Blackhole_State:
		return blackhole_next(&s, ctx)
	case Thunderstorm_State:
		return thunderstorm_next(&s, ctx)
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
