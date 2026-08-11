package bench

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import linux "core:sys/linux"
import "core:time"

// Benchmark the Odin port against the Rust ttfx reference using their real
// user-facing CLIs. Frame pacing is disabled; timings measure render
// throughput. Execute from the repository root:
//
//   odin build bench -o:speed -out:bench/bench
//   BENCH_MIN_SECONDS=1 ./bench/bench [repeats] [effect ...]

REPEATS_DEFAULT :: 5
MIN_SAMPLE_SECONDS_DEFAULT :: 2.0
BENCH_COLUMNS :: 200
BENCH_LINES :: 50
BENCH_INPUT_WIDTH :: BENCH_COLUMNS - 10
BENCH_INPUT_ROWS :: BENCH_LINES - 4

ODIN_BINARY :: "./otfx"
RUST_BINARY :: "./third_party/ttfx/target/release/ttfx"

Frame_Prefix :: [4]byte{'\x1b', '8', '\x1b', '7'}

Effects :: [?]string {
	"beams",
	"binarypath",
	"blackhole",
	"bouncyballs",
	"bubbles",
	"burn",
	"colorshift",
	"crumble",
	"decrypt",
	"errorcorrect",
	"expand",
	"fireworks",
	"highlight",
	"laseretch",
	"matrix",
	"middleout",
	"orbittingvolley",
	"overflow",
	"pour",
	"print",
	"rain",
	"randomsequence",
	"rings",
	"scattered",
	"slice",
	"slide",
	"smoke",
	"spotlights",
	"spray",
	"swarm",
	"sweep",
	"synthgrid",
	"unstable",
	"vhstape",
	"waves",
	"wipe",
	"thunderstorm",
}

Bench_Run :: struct {
	wall_ms: f64,
	cpu_ms:  f64,
	frames:  int,
	rss_kib: int,
}

Bench_Summary :: struct {
	best_wall_ms: f64,
	mean_wall_ms: f64,
	mean_cpu_ms:  f64,
	peak_rss_kib: int,
	batch_count:  int,
}

effect_known :: proc(effect: string) -> bool {
	for candidate in Effects {
		if effect == candidate do return true
	}
	return false
}

effect_is_wall_clock_gated :: proc(effect: string) -> bool {
	return effect == "matrix" || effect == "thunderstorm"
}

make_input :: proc() -> [dynamic]byte {
	input: [dynamic]byte
	reserve(&input, BENCH_INPUT_ROWS * (BENCH_INPUT_WIDTH + 1))
	for row in 0 ..< BENCH_INPUT_ROWS {
		line := fmt.tprintf(
			"benchmark line %03d - the quick brown fox jumps over the lazy dog",
			row,
		)
		for width := 0; width < BENCH_INPUT_WIDTH; {
			count := min(BENCH_INPUT_WIDTH - width, len(line))
			append(&input, ..transmute([]byte)line[:count])
			width += count
		}
		if row + 1 < BENCH_INPUT_ROWS do append(&input, '\n')
	}
	return input
}

write_all :: proc(file: ^os.File, data: []byte) -> bool {
	remaining := data
	for len(remaining) > 0 {
		count, err := os.write(file, remaining)
		if err != nil || count <= 0 do return false
		remaining = remaining[count:]
	}
	return true
}

frame_count_append :: proc(bytes: []byte, matched: ^int) -> int {
	prefix := Frame_Prefix
	count := 0
	for b in bytes {
		if b == prefix[matched^] {
			matched^ += 1
			if matched^ == len(prefix) {
				count += 1
				matched^ = 0
			}
		} else if b == prefix[0] {
			matched^ = 1
		} else {
			matched^ = 0
		}
	}
	return count
}

run_command :: proc(
	command: []string,
	input: []byte,
	capture_frames, measure_rss: bool,
) -> (
	Bench_Run,
	bool,
) {
	assert(!capture_frames || !measure_rss)
	stdin_r, stdin_w, pipe_err := os.pipe()
	if pipe_err != nil {
		fmt.eprintfln("failed to create child stdin pipe: %v", pipe_err)
		return {}, false
	}
	desc := os.Process_Desc {
		command = command,
		stdin   = stdin_r,
	}

	stdout_r, stdout_w: ^os.File
	if capture_frames {
		stdout_r, stdout_w, pipe_err = os.pipe()
		if pipe_err != nil {
			os.close(stdin_r)
			os.close(stdin_w)
			fmt.eprintfln("failed to create child stdout pipe: %v", pipe_err)
			return {}, false
		}
		desc.stdout = stdout_w
	}
	defer if capture_frames do os.close(stdout_r)

	start := time.tick_now()
	process, start_err := os.process_start(desc)
	os.close(stdin_r)
	if capture_frames do os.close(stdout_w)
	if start_err != nil {
		os.close(stdin_w)
		fmt.eprintfln("failed to start %s: %v", command[0], start_err)
		return {}, false
	}

	if !write_all(stdin_w, input) {
		os.close(stdin_w)
		_ = os.process_kill(process)
		_, _ = os.process_wait(process)
		fmt.eprintfln("failed to write benchmark input to %s", command[0])
		return {}, false
	}
	os.close(stdin_w)

	frames := 0
	if capture_frames {
		buffer: [4096]byte
		matched := 0
		output_done := false
		for !output_done {
			count, read_err := os.read(stdout_r, buffer[:])
			if count > 0 do frames += frame_count_append(buffer[:count], &matched)
			switch read_err {
			case nil:
			case .EOF, .Broken_Pipe:
				output_done = true
			case:
				_ = os.process_kill(process)
				_, _ = os.process_wait(process)
				fmt.eprintfln("failed to read %s output: %v", command[0], read_err)
				return {}, false
			}
		}
	}

	state: os.Process_State
	rss_kib := 0
	if measure_rss {
		status: u32
		usage: linux.RUsage
		for {
			waited, wait_errno := linux.wait4(linux.Pid(process.pid), &status, {}, &usage)
			if wait_errno == .EINTR do continue
			if wait_errno != .NONE || int(waited) != process.pid || status != 0 {
				_, _ = os.process_wait(process, 0)
				fmt.eprintfln("%s exited unsuccessfully while measuring RSS", command[0])
				return {}, false
			}
			break
		}
		_, _ = os.process_wait(process, 0) // closes the pidfd after wait4 reaps it
		rss_kib = usage.maxrss_word
	} else {
		wait_err: os.Error
		state, wait_err = os.process_wait(process)
		if wait_err != nil || !state.success {
			fmt.eprintfln(
				"%s exited unsuccessfully: %v (code %d)",
				command[0],
				wait_err,
				state.exit_code,
			)
			return {}, false
		}
	}
	return {
			wall_ms = time.duration_seconds(time.tick_since(start)) * 1000,
			cpu_ms = time.duration_seconds(state.user_time + state.system_time) * 1000,
			frames = frames,
			rss_kib = rss_kib,
		},
		true
}

command_make :: proc(binary, effect: string) -> [dynamic]string {
	command: [dynamic]string
	append(&command, binary, "--seed", "1", "--frame-rate", "0", effect)
	switch effect {
	case "matrix":
		rain_time := os.get_env("BENCH_MATRIX_RAIN_TIME", context.temp_allocator)
		if rain_time == "" do rain_time = "5"
		append(&command, "--rain-time", rain_time)
	case "thunderstorm":
		storm_time := os.get_env("BENCH_STORM_TIME", context.temp_allocator)
		if storm_time == "" do storm_time = "1"
		append(&command, "--storm-time", storm_time)
	}
	return command
}

benchmark_summary :: proc(
	command: []string,
	input: []byte,
	repeats: int,
	minimum_seconds: f64,
) -> (
	Bench_Summary,
	bool,
) {
	probe, probe_ok := run_command(command, input, false, false)
	if !probe_ok do return {}, false
	batch_count := max(1, int(math.ceil(minimum_seconds / (probe.wall_ms / 1000))))
	best_wall_ms := math.F64_MAX
	total_wall_ms, total_cpu_ms: f64
	run_count := 0
	for _ in 0 ..< repeats {
		start := time.tick_now()
		for _ in 0 ..< batch_count {
			run, run_ok := run_command(command, input, false, false)
			if !run_ok do return {}, false
			total_cpu_ms += run.cpu_ms
			run_count += 1
		}
		elapsed_ms := time.duration_seconds(time.tick_since(start)) * 1000 / f64(batch_count)
		best_wall_ms = min(best_wall_ms, elapsed_ms)
		total_wall_ms += elapsed_ms * f64(batch_count)
	}
	rss_run, rss_ok := run_command(command, input, false, true)
	if !rss_ok do return {}, false
	return {
			best_wall_ms = best_wall_ms,
			mean_wall_ms = total_wall_ms / f64(run_count),
			mean_cpu_ms = total_cpu_ms / f64(run_count),
			peak_rss_kib = rss_run.rss_kib,
			batch_count = batch_count,
		},
		true
}

frame_count :: proc(binary, effect: string, input: []byte) -> (int, bool) {
	command := command_make(binary, effect)
	defer delete(command)
	run, ok := run_command(command[:], input, true, false)
	return run.frames, ok
}

startup :: proc(binary: string, input: []byte, repeats: int, minimum_seconds: f64) -> (f64, bool) {
	command := command_make(binary, "slide")
	defer delete(command)
	summary, ok := benchmark_summary(command[:], input, repeats, minimum_seconds)
	return summary.best_wall_ms, ok
}

parse_options :: proc() -> (repeats: int, selected: [dynamic]string, ok: bool) {
	repeats = REPEATS_DEFAULT
	args := os.args[1:]
	if len(args) > 0 {
		parsed, parsed_ok := strconv.parse_int(args[0])
		if !parsed_ok || parsed <= 0 {
			fmt.eprintfln("usage: %s [repeats] [effect ...]", os.args[0])
			return 0, nil, false
		}
		repeats = parsed
		args = args[1:]
	}
	if len(args) == 0 {
		for effect in Effects do append(&selected, effect)
		return repeats, selected, true
	}
	for effect in args {
		if !effect_known(effect) {
			fmt.eprintfln("unknown effect: %s", effect)
			return 0, nil, false
		}
	}
	append(&selected, ..args)
	return repeats, selected, true
}

minimum_sample_seconds :: proc() -> f64 {
	value := os.get_env("BENCH_MIN_SECONDS", context.temp_allocator)
	if value == "" do return MIN_SAMPLE_SECONDS_DEFAULT
	seconds, ok := strconv.parse_f64(value)
	if !ok || seconds <= 0 {
		fmt.eprintfln("ignoring invalid BENCH_MIN_SECONDS=%s", value)
		return MIN_SAMPLE_SECONDS_DEFAULT
	}
	return seconds
}

main :: proc() {
	repeats, selected, options_ok := parse_options()
	if !options_ok do os.exit(2)
	defer delete(selected)

	if os.set_env("COLUMNS", "200") != nil || os.set_env("LINES", "50") != nil {
		fmt.eprintln("failed to set benchmark terminal dimensions")
		os.exit(1)
	}
	input := make_input()
	defer delete(input)
	minimum_seconds := minimum_sample_seconds()

	fmt.printf(
		"canvas %dx%d, best of %d, >=%gs per sample, frame pacing disabled\n\n",
		BENCH_COLUMNS,
		BENCH_LINES,
		repeats,
		minimum_seconds,
	)
	fmt.println("effect            best wall / batch / frames / ratio")
	fmt.println(
		"-------------------------------------------------------------------------------------------",
	)

	throughput_effect_count := 0
	rust_best_total, odin_best_total: f64
	rust_cpu_total, odin_cpu_total: f64
	rust_rss_total, odin_rss_total: f64
	log_speedup_total: f64

	for effect in selected {
		rust_command := command_make(RUST_BINARY, effect)
		odin_command := command_make(ODIN_BINARY, effect)
		rust_summary, rust_ok := benchmark_summary(
			rust_command[:],
			input[:],
			repeats,
			minimum_seconds,
		)
		odin_summary, odin_ok := benchmark_summary(
			odin_command[:],
			input[:],
			repeats,
			minimum_seconds,
		)
		delete(rust_command)
		delete(odin_command)
		if !rust_ok || !odin_ok do os.exit(1)

		rust_frames, rust_frames_ok := frame_count(RUST_BINARY, effect, input[:])
		odin_frames, odin_frames_ok := frame_count(ODIN_BINARY, effect, input[:])
		if !rust_frames_ok || !odin_frames_ok do os.exit(1)

		fmt.printf(
			"%-16s rust=%.1fms odin=%.1fms batch=%d/%d frames=%d/%d ratio=%.2fx\n",
			effect,
			rust_summary.best_wall_ms,
			odin_summary.best_wall_ms,
			rust_summary.batch_count,
			odin_summary.batch_count,
			rust_frames,
			odin_frames,
			rust_summary.best_wall_ms / odin_summary.best_wall_ms,
		)
		fmt.printf(
			"  mean wall %.1fms / %.1fms, mean CPU %.1fms / %.1fms, peak RSS %d KiB / %d KiB\n",
			rust_summary.mean_wall_ms,
			odin_summary.mean_wall_ms,
			rust_summary.mean_cpu_ms,
			odin_summary.mean_cpu_ms,
			rust_summary.peak_rss_kib,
			odin_summary.peak_rss_kib,
		)
		if effect_is_wall_clock_gated(effect) {
			fmt.println(
				"  wall-clock gated: ratio and frames are diagnostics, not normalized throughput",
			)
		} else {
			throughput_effect_count += 1
			rust_best_total += rust_summary.best_wall_ms
			odin_best_total += odin_summary.best_wall_ms
			rust_cpu_total += rust_summary.mean_cpu_ms
			odin_cpu_total += odin_summary.mean_cpu_ms
			rust_rss_total += f64(rust_summary.peak_rss_kib)
			odin_rss_total += f64(odin_summary.peak_rss_kib)
			log_speedup_total += math.ln(rust_summary.best_wall_ms / odin_summary.best_wall_ms)
		}
	}

	if throughput_effect_count > 0 {
		count := f64(throughput_effect_count)
		rust_best_mean := rust_best_total / count
		odin_best_mean := odin_best_total / count
		rust_cpu_mean := rust_cpu_total / count
		odin_cpu_mean := odin_cpu_total / count
		rust_rss_mean := rust_rss_total / count
		odin_rss_mean := odin_rss_total / count
		fmt.println(
			"-------------------------------------------------------------------------------------------",
		)
		fmt.printf("throughput summary (%d effects, unweighted means):\n", throughput_effect_count)
		fmt.printf(
			"  best wall %.1fms / %.1fms, mean CPU %.1fms / %.1fms, peak RSS %.1f MiB / %.1f MiB\n",
			rust_best_mean,
			odin_best_mean,
			rust_cpu_mean,
			odin_cpu_mean,
			rust_rss_mean / 1024,
			odin_rss_mean / 1024,
		)
		fmt.printf(
			"  geometric wall-speedup %.2fx, Odin/Rust CPU %.2fx, Odin/Rust RSS %.2fx\n",
			math.exp(log_speedup_total / count),
			odin_cpu_mean / rust_cpu_mean,
			odin_rss_mean / rust_rss_mean,
		)
	}

	startup_input := [2]byte{'x', '\n'}
	rust_startup, rust_startup_ok := startup(
		RUST_BINARY,
		startup_input[:],
		repeats,
		minimum_seconds,
	)
	odin_startup, odin_startup_ok := startup(
		ODIN_BINARY,
		startup_input[:],
		repeats,
		minimum_seconds,
	)
	if !rust_startup_ok || !odin_startup_ok do os.exit(1)
	fmt.printf(
		"startup (slide, x): rust=%.1fms odin=%.1fms ratio=%.2fx\n",
		rust_startup,
		odin_startup,
		rust_startup / odin_startup,
	)
}
