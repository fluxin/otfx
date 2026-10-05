package effects

import "../engine"

import "core:math"
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

Effect_Metadata :: struct {
	name:       string,
	blurb:      string,
	flag_names: string,
}

@(rodata)
Effect_Catalog := [Effect_Kind]Effect_Metadata {
	.Slide = {
		name       = "slide",
		blurb      = "slide characters in from outside the canvas",
		flag_names = "--movement-speed --grouping --gap --reverse-direction --merge --movement-easing --final-gradient-stops --final-gradient-steps --final-gradient-frames --final-gradient-direction",
	},
	.Beams = {
		name       = "beams",
		blurb      = "beams illuminate the canvas",
		flag_names = "--beam-row-symbols --beam-column-symbols --beam-delay --beam-row-speed-range --beam-column-speed-range --beam-gradient-stops --beam-gradient-steps --beam-gradient-frames --final-gradient-stops --final-gradient-steps --final-gradient-frames --final-gradient-direction --final-wipe-speed",
	},
	.Rings = {
		name       = "rings",
		blurb      = "characters form spinning rings",
		flag_names = "--ring-colors --ring-gap --spin-duration --spin-speed --disperse-duration --spin-disperse-cycles --final-gradient-stops --final-gradient-steps --final-gradient-direction",
	},
	.Waves = {
		name       = "waves",
		blurb      = "waves travel across the text",
		flag_names = "--wave-symbols --wave-gradient-stops --wave-gradient-steps --wave-count --wave-length --wave-direction --wave-easing --final-gradient-stops --final-gradient-steps --final-gradient-direction",
	},
	.Matrix = {
		name       = "matrix",
		blurb      = "matrix digital rain",
		flag_names = "--highlight-color --rain-color-gradient --rain-symbols --rain-fall-delay-range --rain-column-delay-range --rain-time --symbol-swap-chance --color-swap-chance --resolve-delay --final-gradient-stops --final-gradient-steps --final-gradient-frames --final-gradient-direction",
	},
	.Decrypt = {
		name       = "decrypt",
		blurb      = "movie-style decryption",
		flag_names = "--typing-speed --ciphertext-colors --final-gradient-stops --final-gradient-steps --final-gradient-direction",
	},
	.Rain = {
		name       = "rain",
		blurb      = "rain drops from the top",
		flag_names = "--rain-colors --movement-speed --rain-symbols --final-gradient-stops --final-gradient-steps --final-gradient-direction --movement-easing",
	},
	.Wipe = {
		name       = "wipe",
		blurb      = "wipe the text into view",
		flag_names = "--wipe-direction --wipe-delay --wipe-ease --final-gradient-stops --final-gradient-steps --final-gradient-frames --final-gradient-direction",
	},
	.Scattered = {
		name       = "scattered",
		blurb      = "scatter and reassemble",
		flag_names = "--movement-speed --movement-easing --final-gradient-stops --final-gradient-steps --final-gradient-frames --final-gradient-direction",
	},
	.Expand = {
		name       = "expand",
		blurb      = "expand from the center",
		flag_names = "--expand-easing --movement-speed --final-gradient-stops --final-gradient-steps --final-gradient-direction",
	},
	.Middleout = {
		name       = "middleout",
		blurb      = "expand from the middle row",
		flag_names = "--starting-color --expand-direction --center-movement-speed --full-movement-speed --center-easing --full-easing --final-gradient-stops --final-gradient-steps --final-gradient-direction",
	},
	.Colorshift = {
		name       = "colorshift",
		blurb      = "shifting color gradient",
		flag_names = "--gradient-stops --gradient-steps --gradient-frames --no-travel --travel-direction --reverse-travel-direction --no-loop --cycles --skip-final-gradient --final-gradient-stops --final-gradient-steps --final-gradient-direction",
	},
	.Highlight = {
		name       = "highlight",
		blurb      = "specular highlight sweep",
		flag_names = "--highlight-brightness --highlight-direction --highlight-width --final-gradient-stops --final-gradient-steps --final-gradient-direction",
	},
	.Sweep = {
		name       = "sweep",
		blurb      = "sweep reveal, then color",
		flag_names = "--sweep-symbols --first-sweep-direction --second-sweep-direction --final-gradient-stops --final-gradient-steps --final-gradient-direction",
	},
	.Randomsequence = {
		name       = "randomsequence",
		blurb      = "random reveal sequence",
		flag_names = "--speed --final-gradient-stops --final-gradient-steps --final-gradient-frames --final-gradient-direction",
	},
	.Pour = {
		name       = "pour",
		blurb      = "pour characters into place",
		flag_names = "--pour-direction --pour-speed --movement-speed-range --gap --starting-color --final-gradient-stops --final-gradient-steps --final-gradient-frames --final-gradient-direction --movement-easing",
	},
	.Bouncyballs = {
		name       = "bouncyballs",
		blurb      = "drop bouncing balls into place",
		flag_names = "--ball-colors --ball-symbols --ball-delay --movement-speed --movement-easing --final-gradient-stops --final-gradient-steps --final-gradient-direction",
	},
	.Spray = {
		name       = "spray",
		blurb      = "spray characters from one point",
		flag_names = "--spray-position --spray-volume --movement-speed-range --movement-easing --final-gradient-stops --final-gradient-steps --final-gradient-direction",
	},
	.Slice = {
		name       = "slice",
		blurb      = "slide sliced text halves into place",
		flag_names = "--slice-direction --movement-speed --movement-easing --final-gradient-stops --final-gradient-steps --final-gradient-direction",
	},
	.Overflow = {
		name       = "overflow",
		blurb      = "overflow shuffled rows before settling",
		flag_names = "--overflow-gradient-stops --overflow-cycles-range --overflow-speed --final-gradient-stops --final-gradient-steps --final-gradient-direction",
	},
	.Print = {
		name       = "print",
		blurb      = "type lines with a moving print head",
		flag_names = "--print-head-return-speed --print-speed --print-head-easing --final-gradient-stops --final-gradient-steps --final-gradient-direction",
	},
	.Errorcorrect = {
		name       = "errorcorrect",
		blurb      = "swap misplaced characters back into place",
		flag_names = "--error-pairs --swap-delay --error-color --correct-color --movement-speed --final-gradient-stops --final-gradient-steps --final-gradient-direction",
	},
	.Unstable = {
		name       = "unstable",
		blurb      = "rumble, explode, and reassemble the text",
		flag_names = "--unstable-color --explosion-ease --explosion-speed --reassembly-ease --reassembly-speed --final-gradient-stops --final-gradient-steps --final-gradient-direction",
	},
	.Smoke = {
		name       = "smoke",
		blurb      = "flood the text with a rising smoke front",
		flag_names = "--starting-color --smoke-symbols --smoke-gradient-stops --use-whole-canvas --final-gradient-stops --final-gradient-steps --final-gradient-direction",
	},
	.Burn = {
		name       = "burn",
		blurb      = "burn characters into their final color",
		flag_names = "--starting-color --burn-colors --smoke-chance --final-gradient-stops --final-gradient-steps --final-gradient-direction",
	},
	.Crumble = {
		name       = "crumble",
		blurb      = "crumble, vacuum, and restore the text",
		flag_names = "--final-gradient-stops --final-gradient-steps --final-gradient-direction",
	},
	.Fireworks = {
		name       = "fireworks",
		blurb      = "launch shells that bloom into the text",
		flag_names = "--explode-anywhere --firework-colors --firework-symbol --firework-volume --launch-delay --explode-distance --final-gradient-stops --final-gradient-steps --final-gradient-direction",
	},
	.Spotlights = {
		name       = "spotlights",
		blurb      = "search the text with moving spotlights",
		flag_names = "--beam-width-ratio --beam-falloff --search-duration --search-speed-range --spotlight-count --final-gradient-stops --final-gradient-steps --final-gradient-direction",
	},
	.Vhstape = {
		name       = "vhstape",
		blurb      = "glitch rows, add static, then redraw",
		flag_names = "--glitch-line-colors --glitch-wave-colors --noise-colors --glitch-line-chance --noise-chance --total-glitch-time --final-gradient-stops --final-gradient-steps --final-gradient-direction",
	},
	.Orbittingvolley = {
		name       = "orbittingvolley",
		blurb      = "orbiting launchers volley text into place",
		flag_names = "--top-launcher-symbol --right-launcher-symbol --bottom-launcher-symbol --left-launcher-symbol --launcher-movement-speed --character-movement-speed --volley-size --launch-delay --character-easing --final-gradient-stops --final-gradient-steps --final-gradient-direction",
	},
	.Synthgrid = {
		name       = "synthgrid",
		blurb      = "grow a synth grid and generate the text",
		flag_names = "--grid-gradient-stops --grid-gradient-steps --grid-gradient-direction --text-gradient-stops --text-gradient-steps --text-gradient-direction --grid-row-symbol --grid-column-symbol --text-generation-symbols --max-active-blocks",
	},
	.Bubbles = {
		name       = "bubbles",
		blurb      = "float text in bubbles, pop, and settle",
		flag_names = "--rainbow --bubble-colors --pop-color --bubble-speed --bubble-delay --pop-condition --movement-easing --final-gradient-stops --final-gradient-steps --final-gradient-direction",
	},
	.Binarypath = {
		name       = "binarypath",
		blurb      = "send binary glyphs through the canvas",
		flag_names = "--binary-colors --movement-speed --active-binary-groups --final-gradient-stops --final-gradient-steps --final-gradient-direction",
	},
	.Swarm = {
		name       = "swarm",
		blurb      = "move glyphs through coordinated swarms",
		flag_names = "--base-color --flash-color --swarm-size --swarm-coordination --swarm-area-count-range --final-gradient-stops --final-gradient-steps --final-gradient-direction",
	},
	.Laseretch = {
		name       = "laseretch",
		blurb      = "etch text with a scanning laser",
		flag_names = "--etch-pattern --etch-speed --etch-delay --cool-gradient-stops --laser-gradient-stops --spark-gradient-stops --spark-cooling-frames --final-gradient-stops --final-gradient-steps --final-gradient-frames --final-gradient-direction",
	},
	.Blackhole = {
		name       = "blackhole",
		blurb      = "form, collapse, and explode a black hole",
		flag_names = "--blackhole-color --star-colors --final-gradient-stops --final-gradient-steps --final-gradient-direction",
	},
	.Thunderstorm = {
		name       = "thunderstorm",
		blurb      = "rain and lightning strike through the text",
		flag_names = "--lightning-color --glowing-text-color --text-glow-time --raindrop-symbols --spark-symbols --spark-glow-color --spark-glow-time --storm-time --final-gradient-stops --final-gradient-steps --final-gradient-frames --final-gradient-direction",
	},
}

effect_name :: #force_inline proc(kind: Effect_Kind) -> string {
	return Effect_Catalog[kind].name
}

effect_kind_parse :: proc(name: string) -> (Effect_Kind, bool) {
	catalog := Effect_Catalog
	for kind in Effect_Kind {
		if catalog[kind].name == name do return kind, true
	}
	return .Slide, false
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
	engine.render_prepare(ctx)
}

// Effects publish through particle setters and return whether a frame is ready.
// Visibility is the admission authority; effects need no parallel render list.
next_frame :: proc(effect: ^Effect, ctx: ^engine.Engine) -> bool {
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
		return false
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
	engine.prep_canvas(ctx.cfg.reuse_canvas, ctx.layout.visible_right, ctx.layout.visible_top)
	frames := 0
	for ctx.cfg.max_frames == nil || frames < ctx.cfg.max_frames.? {
		defer free_all(context.temp_allocator)
		if resize_aware && engine.resize_settled(ctx) {
			engine.reset_canvas_area()
			return .Terminal_Resized
		}
		produced := next_frame(effect, ctx)
		if !produced do break
		engine.frame(ctx)
		if resize_aware && engine.resize_settled(ctx) {
			engine.reset_canvas_area()
			return .Terminal_Resized
		}
		engine.print_frame(ctx)
		frames += 1
	}
	engine.restore_cursor(ctx.layout.visible_top, ctx.cfg.no_restore_cursor, ctx.cfg.no_eol)
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

parse_bool_flag :: #force_inline proc(ptr: ^bool, has_value: bool) -> bool {
	if has_value do return false
	ptr^ = true
	return true
}

parse_int_flag :: proc(
	ptr: ^int,
	args: []string,
	i: ^int,
	value: string,
	has_value: bool,
	minimum := 1,
) -> bool {
	v := opt_value(args, i, value, has_value) or_return
	n := strconv.parse_int(v) or_return
	if n < minimum do return false
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
	v := opt_value(args, i, value, has_value) or_return
	f := strconv.parse_f64(v) or_return
	if math.is_nan(f) || math.is_inf(f) do return false
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
	v := opt_value(args, i, value, has_value) or_return
	ptr^ = engine.parse_cli_color(v) or_return
	return true
}

// List options accept both separate argv values and the legacy quoted form.
// Only the temporary token list is scratch; each string still borrows argv.
opt_list_values :: proc(args: []string, i: ^int, value: string, has_value: bool) -> []string {
	v, ok := opt_value(args, i, value, has_value)
	if !ok do return nil
	fields := make([dynamic]string, context.temp_allocator)
	for {
		if v == " " {
			append(&fields, v)
		} else {
			append(&fields, ..strings.fields(v, context.temp_allocator))
		}
		if i^ + 1 == len(args) || strings.has_prefix(args[i^ + 1], "--") do break
		i^ += 1
		v = args[i^]
	}
	return fields[:]
}

parse_colors_flag :: proc(
	list: ^[dynamic]engine.Color,
	args: []string,
	i: ^int,
	value: string,
	has_value: bool,
) -> bool {
	fields := opt_list_values(args, i, value, has_value)
	if len(fields) == 0 do return false
	clear(list)
	for field in fields {
		c := engine.parse_cli_color(field) or_return
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
	fields := opt_list_values(args, i, value, has_value)
	if len(fields) == 0 do return false
	clear(list)
	for field in fields {
		n := strconv.parse_int(field) or_return
		if n <= 0 do return false
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
	v := opt_value(args, i, value, has_value) or_return
	ptr^ = engine.easing_parse(v) or_return
	return true
}

parse_gdir_flag :: proc(
	ptr: ^engine.Gradient_Direction,
	args: []string,
	i: ^int,
	value: string,
	has_value: bool,
) -> bool {
	v := opt_value(args, i, value, has_value) or_return
	ptr^ = engine.gdir_parse(v) or_return
	return true
}

parse_group_flag :: proc(
	ptr: ^engine.Particle_Group,
	args: []string,
	i: ^int,
	value: string,
	has_value: bool,
) -> bool {
	v := opt_value(args, i, value, has_value) or_return
	ptr^ = engine.group_parse(v) or_return
	return true
}

decode_single_symbol :: proc(s: string) -> (rune, bool) {
	symbol, rune_bytes := utf8.decode_rune(s)
	if rune_bytes == 0 || rune_bytes != len(s) || !utf8.valid_string(s) do return 0, false
	if symbol < 0x20 || (symbol >= 0x7f && symbol <= 0x9f) do return 0, false
	return symbol, true
}

parse_symbol_flag :: proc(
	ptr: ^rune,
	args: []string,
	i: ^int,
	value: string,
	has_value: bool,
) -> bool {
	v := opt_value(args, i, value, has_value) or_return
	ptr^ = decode_single_symbol(v) or_return
	return true
}

parse_symbols_flag :: proc(
	list: ^[dynamic]rune,
	args: []string,
	i: ^int,
	value: string,
	has_value: bool,
) -> bool {
	fields := opt_list_values(args, i, value, has_value)
	if len(fields) == 0 do return false
	clear(list)
	for field in fields {
		symbol := decode_single_symbol(field) or_return
		append(list, symbol)
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
	v := opt_value(args, i, value, has_value) or_return
	lo_s, hi_s := split_range(v) or_return
	lo := strconv.parse_f64(lo_s) or_return
	hi := strconv.parse_f64(hi_s) or_return
	if math.is_nan(lo) || math.is_inf(lo) || math.is_nan(hi) || math.is_inf(hi) || lo <= 0 || lo > hi do return false
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
	v := opt_value(args, i, value, has_value) or_return
	lo_s, hi_s := split_range(v) or_return
	lo := strconv.parse_int(lo_s) or_return
	hi := strconv.parse_int(hi_s) or_return
	if lo <= 0 || lo > hi do return false
	ptr^ = {int(lo), int(hi)}
	return true
}

// "lo-hi" range splitter.
split_range :: proc(s: string) -> (lo, hi: string, ok: bool) {
	idx := strings.index(s, "-")
	if idx < 0 do return
	return s[:idx], s[idx + 1:], true
}
