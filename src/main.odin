package main

import effects "./effects"
import engine "./engine"

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:terminal"

// ---------------------------------------------------------------------------
// effect registry
// ---------------------------------------------------------------------------

OTFX_VERSION :: #config(OTFX_VERSION, "0.0.1")

Effect_Kind :: effects.Effect_Kind

Completion_Shell :: enum {
	None,
	Bash,
	Zsh,
}

// Match ttfx's Clap subcommand order for filtered random-effect selection.
Random_Effect_Order :: [37]Effect_Kind {
	.Beams,
	.Binarypath,
	.Blackhole,
	.Bouncyballs,
	.Bubbles,
	.Burn,
	.Colorshift,
	.Crumble,
	.Decrypt,
	.Errorcorrect,
	.Expand,
	.Fireworks,
	.Highlight,
	.Laseretch,
	.Matrix,
	.Middleout,
	.Orbittingvolley,
	.Overflow,
	.Pour,
	.Print,
	.Rain,
	.Randomsequence,
	.Rings,
	.Scattered,
	.Slice,
	.Slide,
	.Smoke,
	.Spotlights,
	.Spray,
	.Swarm,
	.Sweep,
	.Synthgrid,
	.Thunderstorm,
	.Unstable,
	.Vhstape,
	.Waves,
	.Wipe,
}

effect_kind_parse :: proc(name: string) -> (Effect_Kind, bool) {
	return effects.effect_kind_parse(name)
}

effect_kind_name :: #force_inline proc(kind: Effect_Kind) -> string {
	return effects.Effect_Catalog[kind].name
}

effect_blurb :: #force_inline proc(kind: Effect_Kind) -> string {
	return effects.Effect_Catalog[kind].blurb
}

effect_flag_names :: #force_inline proc(kind: Effect_Kind) -> string {
	return effects.Effect_Catalog[kind].flag_names
}

// ---------------------------------------------------------------------------
// terminal options
// ---------------------------------------------------------------------------

Terminal_Opts :: struct {
	cfg:             engine.Terminal_Config,
	seed:            Maybe(u64),
	input_file:      string,
	random:          bool,
	include_effects: [dynamic]string,
	exclude_effects: [dynamic]string,
	completion:      Completion_Shell,
	kind:            Effect_Kind,
	effect_args:     []string,
}

effect_name_in :: #force_inline proc(name: string, names: []string) -> bool {
	for candidate in names {
		if candidate == name do return true
	}
	return false
}

random_effect_pick :: proc(include, exclude: []string) -> (Effect_Kind, bool) {
	candidate_count := 0
	for kind in Random_Effect_Order {
		name := effect_kind_name(kind)
		if len(include) > 0 && !effect_name_in(name, include) do continue
		if effect_name_in(name, exclude) do continue
		candidate_count += 1
	}
	if candidate_count == 0 do return .Slide, false
	selected := engine.random_below(candidate_count)
	for kind in Random_Effect_Order {
		name := effect_kind_name(kind)
		if len(include) > 0 && !effect_name_in(name, include) do continue
		if effect_name_in(name, exclude) do continue
		if selected == 0 do return kind, true
		selected -= 1
	}
	unreachable()
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
		effect_filter_values :: proc(
			args: []string,
			i: ^int,
			value: string,
			has_value: bool,
			out: ^[dynamic]string,
		) -> bool {
			if has_value {
				if value == "" do return false
				append(out, value)
				return true
			}
			start := i^
			for i^ + 1 < len(args) && !strings.has_prefix(args[i^ + 1], "-") {
				i^ += 1
				append(out, args[i^])
			}
			return i^ != start
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
			if has_value do return opts, false
			opts.cfg.wrap_text = true
		case "--xterm-colors":
			if has_value do return opts, false
			opts.cfg.xterm_colors = true
		case "--no-color":
			if has_value do return opts, false
			opts.cfg.no_color = true
		case "--existing-color-handling":
			v, ok := value_of(args, &i, value, has_value)
			if !ok do return opts, false
			handling, ok2 := engine.existing_color_handling_parse(v)
			if !ok2 do return opts, false
			opts.cfg.existing_color_handling = handling
		case "--no-eol":
			if has_value do return opts, false
			opts.cfg.no_eol = true
		case "--no-restore-cursor":
			if has_value do return opts, false
			opts.cfg.no_restore_cursor = true
		case "--ignore-terminal-dimensions":
			if has_value do return opts, false
			opts.cfg.ignore_terminal_dimensions = true
		case "--reuse-canvas":
			if has_value do return opts, false
			opts.cfg.reuse_canvas = true
		case "--virtual-clock":
			if has_value do return opts, false
			opts.cfg.virtual_clock = true
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
			if has_value do return opts, false
			opts.random = true
		case "--include-effects":
			if !effect_filter_values(args, &i, value, has_value, &opts.include_effects) do return opts, false
		case "--exclude-effects":
			if !effect_filter_values(args, &i, value, has_value, &opts.exclude_effects) do return opts, false
		case "--print-completion":
			v, ok := value_of(args, &i, value, has_value)
			if !ok do return opts, false
			switch v {
			case "bash":
				opts.completion = .Bash
			case "zsh":
				opts.completion = .Zsh
			case:
				return opts, false
			}
		case "--version", "-v":
			fmt.printf("otfx %s (odin-native terminal text effects)\n", OTFX_VERSION)
			os.exit(0)
		case "--help", "-h":
			print_usage()
			os.exit(0)
		case:
			fmt.eprintln("Error: unknown option: ", name)
			return opts, false
		}
		i += 1
	}
	if len(opts.include_effects) > 0 && len(opts.exclude_effects) > 0 {
		fmt.eprintln("Error: --include-effects conflicts with --exclude-effects.")
		return opts, false
	}
	if !has_kind && !opts.random && opts.completion == .None {
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
	fmt.println("  --virtual-clock  (advance --rain-time/--storm-time by frames, not wall clock)")
	fmt.println(
		"  --xterm-colors --no-color --existing-color-handling M --no-eol --no-restore-cursor",
	)
	fmt.println("  --tab-width N --terminal-background-color C --seed N -i FILE -R")
	fmt.println(
		"  --include-effects EFFECT... --exclude-effects EFFECT... --print-completion bash|zsh",
	)
	fmt.println("")
	fmt.println("effects:")
	for kind in Effect_Kind {
		fmt.printf("  %-15s %s\n", effect_kind_name(kind), effect_blurb(kind))
	}
	fmt.println("")
	fmt.println("run 'otfx <effect> --help' for effect options")
}

completion_global_words :: proc() -> string {
	return(
		"--frame-rate --canvas-width --canvas-height --anchor-canvas --anchor-text --wrap-text --xterm-colors --no-color --existing-color-handling --no-eol --no-restore-cursor --ignore-terminal-dimensions --reuse-canvas --virtual-clock --tab-width --terminal-background-color --seed --input-file --random-effect --include-effects --exclude-effects --print-completion --help --version" \
	)
}

print_completion_bash :: proc() {
	fmt.println("_otfx() {")
	fmt.println("  local cur effect word")
	fmt.println("  cur=\"${COMP_WORDS[COMP_CWORD]}\"")
	fmt.println("  effect=\"\"")
	fmt.println("  for word in \"${COMP_WORDS[@]:1:COMP_CWORD}\"; do")
	fmt.println("    case \"$word\" in")
	for kind in Random_Effect_Order do fmt.printf("      %s) effect=%s; break ;;\n", effect_kind_name(kind), effect_kind_name(kind))
	fmt.println("    esac")
	fmt.println("  done")
	fmt.printf("  local words=\"%s", completion_global_words())
	for kind in Random_Effect_Order do fmt.printf(" %s", effect_kind_name(kind))
	fmt.println("\"")
	fmt.println("  case \"$effect\" in")
	for kind in Random_Effect_Order do fmt.printf("    %s) words=\"$words %s\" ;;\n", effect_kind_name(kind), effect_flag_names(kind))
	fmt.println("  esac")
	fmt.println("  COMPREPLY=( $(compgen -W \"$words\" -- \"$cur\") )")
	fmt.println("}")
	fmt.println("complete -F _otfx otfx")
}

print_completion_zsh :: proc() {
	fmt.println("#compdef otfx")
	fmt.println("_otfx() {")
	fmt.println("  local -a words")
	fmt.printf("  words=(%s", completion_global_words())
	for kind in Random_Effect_Order do fmt.printf(" %s", effect_kind_name(kind))
	fmt.println(")")
	fmt.println("  _describe 'otfx command' words")
	fmt.println("}")
	fmt.println("_otfx \"$@\"")
}

print_completion :: proc(shell: Completion_Shell) {
	switch shell {
	case .Bash:
		print_completion_bash()
	case .Zsh:
		print_completion_zsh()
	case .None:
		unreachable()
	}
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

	ctx, input_error := engine.engine_make(input, opts.cfg)
	if input_error != .None {
		switch input_error {
		case .Invalid_Tab_Width:
			fmt.eprintln("Error: tab width must be positive")
		case .Unsupported_Escape:
			fmt.eprintln("Error: unsupported ANSI escape sequence in input")
		case .Unsupported_SGR:
			fmt.eprintln("Error: unsupported ANSI SGR sequence in input")
		case .Unsupported_Cursor:
			fmt.eprintln("Error: unsupported ANSI cursor sequence in input")
		case .None:
			unreachable()
		}
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
	defer delete(opts.include_effects)
	defer delete(opts.exclude_effects)
	if opts.completion != .None {
		print_completion(opts.completion)
		return
	}

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

	if seed, has_seed := opts.seed.?; has_seed {
		engine.random_seed(seed)
	} else {
		engine.random_seed_from_clock()
	}
	if opts.random {
		kind, found := random_effect_pick(opts.include_effects[:], opts.exclude_effects[:])
		if !found {
			fmt.eprintln("Error: No effects available after filtering.")
			os.exit(1)
		}
		opts.kind = kind
	}

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
