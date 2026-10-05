package engine

import "base:intrinsics"
import "core:c/libc"
import "core:container/bit_array"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:terminal/ansi"
import "core:time"

// Terminal I/O, cursor lifecycle, resize handling, and explicit capture.

Frame_Origin :: string(ansi.DECRC + ansi.DECSC)

prep_canvas :: proc(reuse_canvas: bool, visible_right, visible_top: int) {
	os.write_string(os.stdout, ansi.CSI + ansi.DECTCEM_HIDE)
	if reuse_canvas do os.write_string(os.stdout, Frame_Origin)
	blank := strings.repeat(" ", max(visible_right, 0))
	defer delete(blank)
	for _ in 0 ..< visible_top {
		os.write_string(os.stdout, blank)
		os.write_string(os.stdout, "\n")
	}
	if visible_top > 0 do os.write_string(os.stdout, move_cursor_up(visible_top))
	os.write_string(os.stdout, ansi.DECSC)
}

// A settled resize ends the current run. Keep the cursor hidden and return to
// the top of the old drawing area so the replacement engine draws in place.
reset_canvas_area :: proc() {
	os.write_string(os.stdout, ansi.DECRC)
	os.write_string(os.stdout, ansi.CSI + "0" + ansi.ED)
	os.flush(os.stdout)
}

restore_cursor :: proc(visible_top: int, no_restore_cursor, no_eol: bool) {
	// The saved position is the canvas top; cleanup moves below the canvas.
	os.write_string(os.stdout, ansi.DECRC)
	if visible_top > 0 do os.write_string(os.stdout, fmt.tprintf("%s%d%s", ansi.CSI, visible_top, ansi.CNL))
	if !no_restore_cursor do os.write_string(os.stdout, ansi.CSI + ansi.DECTCEM_SHOW)
	if !no_eol do os.write_string(os.stdout, "\n")
	os.flush(os.stdout)
}

move_cursor_up :: proc(n: int) -> string {
	return fmt.tprintf("%s%d%s", ansi.CSI, n, ansi.CUU)
}

// The longest cursor move: ESC [ <up to 20 digits> E|G.
MOVE_MAX :: len("\x1b[") + 20 + 1

// Writes ESC [ n final and returns its length. A constant base lets the
// compiler replace the divisions with multiplies.
write_cursor_move :: proc(buf: []byte, n: int, final: byte) -> int #no_bounds_check {
	count := 1
	for rest := n / 10; rest > 0; rest /= 10 do count += 1
	buf[0], buf[1] = '\x1b', '['
	value := n
	for i := 1 + count; i >= 2; i -= 1 {
		buf[i] = '0' + byte(value % 10)
		value /= 10
	}
	buf[2 + count] = final
	return 3 + count
}

// The bytes the terminal last received for a cell.
cell_encoding :: proc(e: ^Engine, index: int) -> []byte {
	return e.slots[index][:e.cells[index].length]
}

// Changed cells go out as runs. Each run starts at an absolute column, so
// unchanged cells cost nothing and glyph widths cannot drift along a row.
// Slots copy whole; the frame advances only past each cell's encoded bytes.
frame_output :: proc(e: ^Engine) -> []byte #no_bounds_check {
	width := e.layout.visible_right
	used := copy(e.output, Frame_Origin)
	cursor_row, row_end, previous := 0, 0, -1
	cells := bit_array.make_iterator(&e.emit_cells)
	for index, ok := next_set_bit(&cells); ok; index, ok = next_set_bit(&cells) {
		if index != previous + 1 || index == row_end {
			row, column := index / width, index % width
			row_end = (row + 1) * width
			// Cursor-next-line also returns to column one.
			if row != cursor_row do used += write_cursor_move(e.output[used:], row - cursor_row, 'E')
			if column != 0 do used += write_cursor_move(e.output[used:], column + 1, 'G')
			cursor_row = row
			when FRAME_STATS_ENABLED {e.stats.runs += 1}
		}
		copy(e.output[used:][:SLOT_MAX], e.slots[index][:])
		used += int(e.cells[index].length)
		previous = index
	}
	when FRAME_STATS_ENABLED {e.stats.output_bytes += used}
	return e.output[:used]
}

// Capture owns its copy, without the frame origin. Terminal output borrows
// the engine's buffer instead.
frame_bytes :: proc(e: ^Engine, allocator := context.temp_allocator) -> []byte {
	return slice.clone(frame_output(e)[len(Frame_Origin):], allocator)
}

// A short write may stop anywhere; retry from that exact byte.
write_all :: proc(fd: linux.Fd, bytes: []byte, e: ^Engine = nil) -> linux.Errno {
	remaining := bytes
	for len(remaining) != 0 {
		when FRAME_STATS_ENABLED {if e != nil do e.stats.write_calls += 1}
		count, err := linux.write(fd, remaining)
		if err == .EINTR do continue
		if err != nil do return err
		if count == 0 do return .EIO
		when FRAME_STATS_ENABLED {if e != nil do e.stats.write_bytes += count}
		remaining = remaining[count:]
	}
	return nil
}

print_frame :: proc(e: ^Engine) {
	when FRAME_STATS_ENABLED {e.stats.clock = time.tick_now()}
	write_all(1, frame_output(e), e)
	os.flush(os.stdout)
	when FRAME_STATS_ENABLED {e.stats.write += time.tick_diff(e.stats.clock, time.tick_now())}
}

// SIGWINCH only records a signal-safe flag. The interactive run loop consumes
// it after a short quiet period, checks whether layout actually changes, then
// returns to main so a fresh engine/effect can be built against new geometry.
resize_signal_pending: libc.sig_atomic_t

resize_signal_handler :: proc "c" (_: i32) {
	intrinsics.atomic_store(&resize_signal_pending, libc.sig_atomic_t(1))
}

install_resize_handler :: proc() {
	_ = libc.signal(28, resize_signal_handler) // SIGWINCH on supported Linux targets
}

take_resize_signal :: proc() -> bool {
	return intrinsics.atomic_exchange(&resize_signal_pending, libc.sig_atomic_t(0)) != 0
}

Winsize :: struct {
	row, col:       u16,
	xpixel, ypixel: u16,
}

ioctl_winsize :: proc(fd: int) -> (int, int) {
	ws: Winsize
	ret := linux.ioctl(linux.Fd(fd), u32(linux.TIOCGWINSZ), uintptr(&ws))
	if int(ret) == 0 do return int(ws.col), int(ws.row)
	return 0, 0
}

terminal_dimensions :: proc() -> (int, int) {
	buf: [256]u8
	c, cok := strconv.parse_int(os.get_env_buf(buf[:], "COLUMNS"))
	l, lok := strconv.parse_int(os.get_env_buf(buf[:], "LINES"))
	if cok && lok do return int(c), int(l)
	w, h := ioctl_winsize(1) // stdout
	if cok do w = int(c)
	if lok do h = int(l)
	if w <= 0 do w = 80
	if h <= 0 do h = 24
	return w, h
}

resize_layout_changed :: proc(e: ^Engine, term_w, term_h: int) -> bool {
	canvas, layout := layout_make(e.cfg, e.input_line_widths[:], term_w, term_h)
	return canvas.top != e.canvas.top || canvas.right != e.canvas.right || layout != e.layout
}

resize_settled :: proc(e: ^Engine) -> bool {
	if take_resize_signal() do e.resize_seen_at = time.tick_now()
	seen, has_seen := e.resize_seen_at.?
	if !has_seen || time.duration_milliseconds(time.tick_since(seen)) < 50 do return false
	e.resize_seen_at = nil
	if e.cfg.ignore_terminal_dimensions do return false
	term_w, term_h := terminal_dimensions()
	if term_w == e.terminal_width && term_h == e.terminal_height do return false
	return resize_layout_changed(e, term_w, term_h)
}
