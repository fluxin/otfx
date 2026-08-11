package main

import effects "./effects"
import engine "./engine"

import "core:fmt"
import rand "core:math/rand"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:terminal"

// ---------------------------------------------------------------------------
// effect registry
// ---------------------------------------------------------------------------

Effect_Kind :: effects.Effect_Kind

effect_kind_parse :: proc(name: string) -> (Effect_Kind, bool) {
	for kind in Effect_Kind {
		if effect_kind_name(kind) == name do return kind, true
	}
	return .Slide, false
}

effect_kind_name :: proc(kind: Effect_Kind) -> string {
	switch kind {
	case .Slide:
		return "slide"
	case .Beams:
		return "beams"
	case .Rings:
		return "rings"
	case .Waves:
		return "waves"
	case .Matrix:
		return "matrix"
	case .Decrypt:
		return "decrypt"
	case .Rain:
		return "rain"
	case .Wipe:
		return "wipe"
	case .Scattered:
		return "scattered"
	case .Expand:
		return "expand"
	case .Middleout:
		return "middleout"
	case .Colorshift:
		return "colorshift"
	case .Highlight:
		return "highlight"
	case .Sweep:
		return "sweep"
	case .Randomsequence:
		return "randomsequence"
	case .Pour:
		return "pour"
	case .Bouncyballs:
		return "bouncyballs"
	case .Spray:
		return "spray"
	case .Slice:
		return "slice"
	case .Overflow:
		return "overflow"
	case .Print:
		return "print"
	case .Errorcorrect:
		return "errorcorrect"
	case .Unstable:
		return "unstable"
	case .Smoke:
		return "smoke"
	case .Burn:
		return "burn"
	case .Crumble:
		return "crumble"
	case .Fireworks:
		return "fireworks"
	case .Spotlights:
		return "spotlights"
	case .Vhstape:
		return "vhstape"
	case .Orbittingvolley:
		return "orbittingvolley"
	case .Synthgrid:
		return "synthgrid"
	case .Bubbles:
		return "bubbles"
	case .Binarypath:
		return "binarypath"
	case .Swarm:
		return "swarm"
	case .Laseretch:
		return "laseretch"
	case .Blackhole:
		return "blackhole"
	case .Thunderstorm:
		return "thunderstorm"
	}
	return "?"
}

effect_blurb :: proc(kind: Effect_Kind) -> string {
	switch kind {
	case .Slide:
		return "slide characters in from outside the canvas"
	case .Beams:
		return "beams illuminate the canvas"
	case .Rings:
		return "characters form spinning rings"
	case .Waves:
		return "waves travel across the text"
	case .Matrix:
		return "matrix digital rain"
	case .Decrypt:
		return "movie-style decryption"
	case .Rain:
		return "rain drops from the top"
	case .Wipe:
		return "wipe the text into view"
	case .Scattered:
		return "scatter and reassemble"
	case .Expand:
		return "expand from the center"
	case .Middleout:
		return "expand from the middle row"
	case .Colorshift:
		return "shifting color gradient"
	case .Highlight:
		return "specular highlight sweep"
	case .Sweep:
		return "sweep reveal, then color"
	case .Randomsequence:
		return "random reveal sequence"
	case .Pour:
		return "pour characters into place"
	case .Bouncyballs:
		return "drop bouncing balls into place"
	case .Spray:
		return "spray characters from one point"
	case .Slice:
		return "slide sliced text halves into place"
	case .Overflow:
		return "overflow shuffled rows before settling"
	case .Print:
		return "type lines with a moving print head"
	case .Errorcorrect:
		return "swap misplaced characters back into place"
	case .Unstable:
		return "rumble, explode, and reassemble the text"
	case .Smoke:
		return "flood the text with a rising smoke front"
	case .Burn:
		return "burn characters into their final color"
	case .Crumble:
		return "crumble, vacuum, and restore the text"
	case .Fireworks:
		return "launch shells that bloom into the text"
	case .Spotlights:
		return "search the text with moving spotlights"
	case .Vhstape:
		return "glitch rows, add static, then redraw"
	case .Orbittingvolley:
		return "orbiting launchers volley text into place"
	case .Synthgrid:
		return "grow a synth grid and generate the text"
	case .Bubbles:
		return "float text in bubbles, pop, and settle"
	case .Binarypath:
		return "send binary glyphs through the canvas"
	case .Swarm:
		return "move glyphs through coordinated swarms"
	case .Laseretch:
		return "etch text with a scanning laser"
	case .Blackhole:
		return "form, collapse, and explode a black hole"
	case .Thunderstorm:
		return "rain and lightning strike through the text"
	}
	return "?"
}

effect_flag_names :: proc(kind: Effect_Kind) -> string {
	switch kind {
	case .Slide:
		return(
			"--movement-speed --grouping --gap --reverse-direction --merge --movement-easing --final-gradient-stops --final-gradient-steps --final-gradient-frames --final-gradient-direction" \
		)
	case .Beams:
		return(
			"--beam-row-symbols --beam-column-symbols --beam-delay --beam-row-speed-range --beam-column-speed-range --beam-gradient-stops --beam-gradient-steps --beam-gradient-frames --final-gradient-stops --final-gradient-steps --final-gradient-frames --final-gradient-direction --final-wipe-speed" \
		)
	case .Rings:
		return(
			"--ring-colors --ring-gap --spin-duration --spin-speed --disperse-duration --spin-disperse-cycles --final-gradient-stops --final-gradient-steps --final-gradient-direction" \
		)
	case .Waves:
		return(
			"--wave-symbols --wave-gradient-stops --wave-gradient-steps --wave-count --wave-length --wave-direction --wave-easing --final-gradient-stops --final-gradient-steps --final-gradient-direction" \
		)
	case .Matrix:
		return(
			"--highlight-color --rain-color-gradient --rain-symbols --rain-fall-delay-range --rain-column-delay-range --rain-time --symbol-swap-chance --color-swap-chance --resolve-delay --final-gradient-stops --final-gradient-steps --final-gradient-frames --final-gradient-direction" \
		)
	case .Decrypt:
		return(
			"--typing-speed --ciphertext-colors --final-gradient-stops --final-gradient-steps --final-gradient-direction" \
		)
	case .Rain:
		return(
			"--rain-colors --movement-speed --rain-symbols --final-gradient-stops --final-gradient-steps --final-gradient-direction --movement-easing" \
		)
	case .Wipe:
		return(
			"--wipe-direction --wipe-delay --wipe-ease --final-gradient-stops --final-gradient-steps --final-gradient-frames --final-gradient-direction" \
		)
	case .Scattered:
		return(
			"--movement-speed --movement-easing --final-gradient-stops --final-gradient-steps --final-gradient-frames --final-gradient-direction" \
		)
	case .Expand:
		return(
			"--expand-easing --movement-speed --final-gradient-stops --final-gradient-steps --final-gradient-direction" \
		)
	case .Middleout:
		return(
			"--starting-color --expand-direction --center-movement-speed --full-movement-speed --center-easing --full-easing --final-gradient-stops --final-gradient-steps --final-gradient-direction" \
		)
	case .Colorshift:
		return(
			"--gradient-stops --gradient-steps --gradient-frames --no-travel --travel-direction --reverse-travel-direction --no-loop --cycles --skip-final-gradient --final-gradient-stops --final-gradient-steps --final-gradient-direction" \
		)
	case .Highlight:
		return(
			"--highlight-brightness --highlight-direction --highlight-width --final-gradient-stops --final-gradient-steps --final-gradient-direction" \
		)
	case .Sweep:
		return(
			"--sweep-symbols --first-sweep-direction --second-sweep-direction --final-gradient-stops --final-gradient-steps --final-gradient-direction" \
		)
	case .Randomsequence:
		return(
			"--speed --final-gradient-stops --final-gradient-steps --final-gradient-frames --final-gradient-direction" \
		)
	case .Pour:
		return(
			"--pour-direction --pour-speed --movement-speed-range --gap --starting-color --final-gradient-stops --final-gradient-steps --final-gradient-frames --final-gradient-direction --movement-easing" \
		)
	case .Bouncyballs:
		return(
			"--ball-colors --ball-symbols --ball-delay --movement-speed --movement-easing --final-gradient-stops --final-gradient-steps --final-gradient-direction" \
		)
	case .Spray:
		return(
			"--spray-position --spray-volume --movement-speed-range --movement-easing --final-gradient-stops --final-gradient-steps --final-gradient-direction" \
		)
	case .Slice:
		return(
			"--slice-direction --movement-speed --movement-easing --final-gradient-stops --final-gradient-steps --final-gradient-direction" \
		)
	case .Overflow:
		return(
			"--overflow-gradient-stops --overflow-cycles-range --overflow-speed --final-gradient-stops --final-gradient-steps --final-gradient-direction" \
		)
	case .Print:
		return(
			"--print-head-return-speed --print-speed --print-head-easing --final-gradient-stops --final-gradient-steps --final-gradient-direction" \
		)
	case .Errorcorrect:
		return(
			"--error-pairs --swap-delay --error-color --correct-color --movement-speed --final-gradient-stops --final-gradient-steps --final-gradient-direction" \
		)
	case .Unstable:
		return(
			"--unstable-color --explosion-ease --explosion-speed --reassembly-ease --reassembly-speed --final-gradient-stops --final-gradient-steps --final-gradient-direction" \
		)
	case .Smoke:
		return(
			"--starting-color --smoke-symbols --smoke-gradient-stops --use-whole-canvas --final-gradient-stops --final-gradient-steps --final-gradient-direction" \
		)
	case .Burn:
		return(
			"--starting-color --burn-colors --smoke-chance --final-gradient-stops --final-gradient-steps --final-gradient-direction" \
		)
	case .Crumble:
		return "--final-gradient-stops --final-gradient-steps --final-gradient-direction"
	case .Fireworks:
		return(
			"--explode-anywhere --firework-colors --firework-symbol --firework-volume --launch-delay --explode-distance --final-gradient-stops --final-gradient-steps --final-gradient-direction" \
		)
	case .Spotlights:
		return(
			"--beam-width-ratio --beam-falloff --search-duration --search-speed-range --spotlight-count --final-gradient-stops --final-gradient-steps --final-gradient-direction" \
		)
	case .Vhstape:
		return(
			"--glitch-line-colors --glitch-wave-colors --noise-colors --glitch-line-chance --noise-chance --total-glitch-time --final-gradient-stops --final-gradient-steps --final-gradient-direction" \
		)
	case .Orbittingvolley:
		return(
			"--top-launcher-symbol --right-launcher-symbol --bottom-launcher-symbol --left-launcher-symbol --launcher-movement-speed --character-movement-speed --volley-size --launch-delay --character-easing --final-gradient-stops --final-gradient-steps --final-gradient-direction" \
		)
	case .Synthgrid:
		return(
			"--grid-gradient-stops --grid-gradient-steps --grid-gradient-direction --text-gradient-stops --text-gradient-steps --text-gradient-direction --grid-row-symbol --grid-column-symbol --text-generation-symbols --max-active-blocks" \
		)
	case .Bubbles:
		return(
			"--rainbow --bubble-colors --pop-color --bubble-speed --bubble-delay --pop-condition --movement-easing --final-gradient-stops --final-gradient-steps --final-gradient-direction" \
		)
	case .Binarypath:
		return(
			"--binary-colors --movement-speed --active-binary-groups --final-gradient-stops --final-gradient-steps --final-gradient-direction" \
		)
	case .Swarm:
		return(
			"--base-color --flash-color --swarm-size --swarm-coordination --swarm-area-count-range --final-gradient-stops --final-gradient-steps --final-gradient-direction" \
		)
	case .Laseretch:
		return(
			"--etch-pattern --etch-speed --etch-delay --cool-gradient-stops --laser-gradient-stops --spark-gradient-stops --spark-cooling-frames --final-gradient-stops --final-gradient-steps --final-gradient-frames --final-gradient-direction" \
		)
	case .Blackhole:
		return(
			"--blackhole-color --star-colors --final-gradient-stops --final-gradient-steps --final-gradient-direction" \
		)
	case .Thunderstorm:
		return(
			"--lightning-color --glowing-text-color --text-glow-time --raindrop-symbols --spark-symbols --spark-glow-color --spark-glow-time --storm-time --final-gradient-stops --final-gradient-steps --final-gradient-frames --final-gradient-direction" \
		)
	}
	return ""
}

// ---------------------------------------------------------------------------
// terminal options
// ---------------------------------------------------------------------------

Terminal_Opts :: struct {
	cfg:         engine.Terminal_Config,
	seed:        Maybe(u64),
	input_file:  string,
	random:      bool,
	kind:        Effect_Kind,
	effect_args: []string,
}

parse_terminal_opts :: proc(args: []string) -> (Terminal_Opts, bool) {
	opts: Terminal_Opts
	opts.cfg = engine.config_default()
	has_kind := false

	i := 0
	for i < len(args) {
		arg := args[i]
		name := arg
		value := ""
		has_value := false
		if strings.has_prefix(arg, "--") {
			if eq := strings.index(arg, "="); eq >= 0 {
				name = arg[:eq]
				value = arg[eq + 1:]
				has_value = true
			}
		}
		if !strings.has_prefix(name, "--") && !has_kind {
			if k, ok := effect_kind_parse(name); ok {
				has_kind = true
				opts.kind = k
				opts.effect_args = args[i + 1:]
				break
			}
		}
		value_of :: proc(
			args: []string,
			i: ^int,
			value: string,
			has_value: bool,
		) -> (
			string,
			bool,
		) {
			if has_value do return value, true
			if i^ + 1 < len(args) {
				i^ += 1
				return args[i^], true
			}
			return "", false
		}
		switch name {
		case "--frame-rate":
			v, ok := value_of(args, &i, value, has_value)
			if !ok do return opts, false
			n, ok2 := strconv.parse_int(v)
			if !ok2 || n < 0 do return opts, false
			opts.cfg.frame_rate = int(n)
		case "--max-frames":
			v, ok := value_of(args, &i, value, has_value)
			if !ok do return opts, false
			n, ok2 := strconv.parse_int(v)
			if !ok2 || n < 0 do return opts, false
			opts.cfg.max_frames = int(n)
		case "--canvas-width":
			v, ok := value_of(args, &i, value, has_value)
			if !ok do return opts, false
			n, ok2 := strconv.parse_int(v)
			if !ok2 || n < -1 do return opts, false
			opts.cfg.canvas_width = int(n)
		case "--canvas-height":
			v, ok := value_of(args, &i, value, has_value)
			if !ok do return opts, false
			n, ok2 := strconv.parse_int(v)
			if !ok2 || n < -1 do return opts, false
			opts.cfg.canvas_height = int(n)
		case "--anchor-canvas":
			v, ok := value_of(args, &i, value, has_value)
			if !ok do return opts, false
			a, ok2 := engine.anchor_parse(v)
			if !ok2 do return opts, false
			opts.cfg.anchor_canvas = a
		case "--anchor-text":
			v, ok := value_of(args, &i, value, has_value)
			if !ok do return opts, false
			a, ok2 := engine.anchor_parse(v)
			if !ok2 do return opts, false
			opts.cfg.anchor_text = a
		case "--wrap-text":
			opts.cfg.wrap_text = true
		case "--xterm-colors":
			opts.cfg.xterm_colors = true
		case "--no-color":
			opts.cfg.no_color = true
		case "--existing-color-handling":
			v, ok := value_of(args, &i, value, has_value)
			if !ok do return opts, false
			handling, ok2 := engine.existing_color_handling_parse(v)
			if !ok2 do return opts, false
			opts.cfg.existing_color_handling = handling
		case "--no-eol":
			opts.cfg.no_eol = true
		case "--no-restore-cursor":
			opts.cfg.no_restore_cursor = true
		case "--ignore-terminal-dimensions":
			opts.cfg.ignore_terminal_dimensions = true
		case "--reuse-canvas":
			opts.cfg.reuse_canvas = true
		case "--tab-width":
			v, ok := value_of(args, &i, value, has_value)
			if !ok do return opts, false
			n, ok2 := strconv.parse_int(v)
			if !ok2 || n <= 0 do return opts, false
			opts.cfg.tab_width = int(n)
		case "--terminal-background-color":
			v, ok := value_of(args, &i, value, has_value)
			if !ok do return opts, false
			c, ok2 := engine.parse_cli_color(v)
			if !ok2 do return opts, false
			opts.cfg.terminal_background_color = c
		case "--seed":
			v, ok := value_of(args, &i, value, has_value)
			if !ok do return opts, false
			n, ok2 := strconv.parse_u64(v)
			if !ok2 do return opts, false
			opts.seed = n
		case "-i", "--input-file":
			v, ok := value_of(args, &i, value, has_value)
			if !ok do return opts, false
			opts.input_file = v
		case "-R", "--random-effect":
			opts.random = true
		case "--version", "-v":
			fmt.println("otfx 0.1.0 (odin port of ttfx)")
			return opts, false
		case "--help", "-h":
			print_usage()
			return opts, false
		case:
			fmt.eprintln("Error: unknown option: ", name)
			return opts, false
		}
		i += 1
	}
	if !has_kind {
		fmt.eprintln("Error: No effect specified.")
		print_usage()
		return opts, false
	}
	return opts, true
}

print_usage :: proc() {
	fmt.println("otfx — terminal text effects (odin-native port of ttfx)")
	fmt.println("")
	fmt.println("usage: <producer> | otfx [terminal options] <effect> [effect options]")
	fmt.println("")
	fmt.println("terminal options:")
	fmt.println("  --frame-rate N   --canvas-width N   --canvas-height N")
	fmt.println("  --anchor-canvas X   --anchor-text X   --wrap-text")
	fmt.println(
		"  --xterm-colors --no-color --existing-color-handling M --no-eol --no-restore-cursor",
	)
	fmt.println("  --tab-width N --terminal-background-color C --seed N -i FILE -R")
	fmt.println("")
	fmt.println("effects:")
	for kind in Effect_Kind {
		fmt.printf("  %-15s %s\n", effect_kind_name(kind), effect_blurb(kind))
	}
	fmt.println("")
	fmt.println("run 'otfx <effect> --help' for effect options")
}

read_stdin_all :: proc() -> []byte {
	buf: [dynamic]byte
	chunk := make([]byte, 64 * 1024)
	defer delete(chunk)
	for {
		n, err := os.read(os.stdin, chunk)
		if n > 0 do append(&buf, ..chunk[:n])
		if err != nil || n == 0 do break
	}
	return buf[:]
}

run_effect_once :: proc(
	input: string,
	opts: Terminal_Opts,
	resize_aware: bool,
	allocator: mem.Allocator,
) -> effects.Run_Outcome {
	context.allocator = allocator

	ctx, input_error, input_ok := engine.engine_make(input, opts.cfg, context.allocator)
	if !input_ok {
		fmt.eprintln("Error: ", input_error)
		os.exit(1)
	}
	effect, effect_ok := effects.make_effect(opts.kind, opts.effect_args)
	if !effect_ok do os.exit(1)
	return effects.run_effect(&effect, &ctx, resize_aware)
}

main :: proc() {
	args := os.args[1:]

	// "<effect> --help" → effect options
	if len(args) >= 2 && args[len(args) - 1] == "--help" {
		if kind, ok := effect_kind_parse(args[0]); ok {
			fmt.printf("otfx %s options:\n  %s\n", effect_kind_name(kind), effect_flag_names(kind))
			return
		}
	}

	opts, ok := parse_terminal_opts(args)
	if !ok do os.exit(1)

	input := opts.input_file
	if input == "" {
		if terminal.is_terminal(os.stdin) {
			input = ""
		} else {
			data := read_stdin_all()
			input = string(data)
		}
	} else {
		data, err := os.read_entire_file(opts.input_file, context.allocator)
		if err != nil {
			fmt.eprintln("Error reading input file")
			os.exit(1)
		}
		input = string(data)
	}

	if strings.trim_space(input) == "" {
		fmt.println("NO INPUT.")
		os.exit(1)
	}

	if seed, has_seed := opts.seed.?; has_seed do rand.reset_u64(seed)
	if opts.random do opts.kind = Effect_Kind(rand.int_max(len(Effect_Kind)))

	resize_aware := terminal.is_terminal(os.stdout)
	if resize_aware do engine.install_resize_handler()
	// One arena backs every rebuilt engine/effect world. Resetting after a
	// resize retains its blocks for the replacement run without retaining any
	// references into the old world.
	run_memory: mem.Dynamic_Arena
	mem.dynamic_arena_init(&run_memory, minimum_alignment = 1)
	defer mem.dynamic_arena_destroy(&run_memory)
	run_allocator := mem.dynamic_arena_allocator(&run_memory)
	for {
		outcome := run_effect_once(input, opts, resize_aware, run_allocator)
		if outcome != .Terminal_Resized do break
		mem.dynamic_arena_reset(&run_memory)
		// The old DEC anchor was cleared by reset_canvas_area. It is valid only
		// for the caller's first run, exactly as in the Rust reference.
		opts.cfg.reuse_canvas = false
	}
}
