package engine

import "base:intrinsics"
import "core:c/libc"
import "core:container/bit_array"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:terminal/ansi"
import "core:time"

// Terminal I/O, cursor lifecycle, resize handling, and explicit capture.

Frame_Origin :: string(ansi.DECRC + ansi.DECSC)

// Cursor-next-line also returns to column one. Storage lives through writev.
row_move :: proc(buf: []byte, rows: int) -> []byte {
	if rows == 0 do return nil
	if rows == 1 do return transmute([]byte)string("\x1b[1E")
	buf[0], buf[1] = '\x1b', '['
	digits := strconv.write_uint(buf[2:], u64(rows), 10)
	end := 2 + len(digits)
	buf[end] = 'E'
	return buf[:end + 1]
}

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

// Capture owns its contiguous copy. Terminal output borrows row bytes instead.
frame_bytes :: proc(e: ^Engine, allocator := context.temp_allocator) -> []byte {
	move: [24]byte
	length, cursor := 0, 0
	rows := bit_array.make_iterator(&e.emit_rows)
	for i, ok := bit_array.iterate_by_set(&rows); ok; i, ok = bit_array.iterate_by_set(&rows) {
		row := &e.rows[i]
		length += len(row_move(move[:], i - cursor)) + len(row.bytes)
		cursor = i
	}
	out := make([]byte, length, allocator)
	used := 0
	cursor = 0
	rows = bit_array.make_iterator(&e.emit_rows)
	for i, ok := bit_array.iterate_by_set(&rows); ok; i, ok = bit_array.iterate_by_set(&rows) {
		used += copy(out[used:], row_move(move[:], i - cursor))
		used += copy(out[used:], e.rows[i].bytes)
		cursor = i
	}
	return out
}

// The syscall boundary is the only consumer needing native iovec descriptors.
// A short write may end inside any slice; retry from that exact byte.
write_vectors :: proc(fd: linux.Fd, vectors: []linux.IO_Vec, e: ^Engine = nil) -> linux.Errno {
	remaining := vectors
	for len(remaining) != 0 {
		if remaining[0].len == 0 {
			remaining = remaining[1:]
			continue
		}
		when FRAME_STATS_ENABLED {if e != nil do e.stats.write_calls += 1}
		count, err := linux.writev(fd, remaining[:min(len(remaining), 1024)])
		when FRAME_STATS_ENABLED {if e != nil && count > 0 do e.stats.write_bytes += int(count)}
		if err == .EINTR do continue
		if err != nil do return err
		if count == 0 do return .EIO
		consumed := uint(count)
		for len(remaining) > 0 && consumed >= remaining[0].len {
			consumed -= remaining[0].len
			remaining = remaining[1:]
		}
		if consumed != 0 {
			remaining[0].base = remaining[0].base[consumed:]
			remaining[0].len -= consumed
		}
	}
	return nil
}

print_frame :: proc(e: ^Engine) {
	when FRAME_STATS_ENABLED {e.stats.clock = time.tick_now()}
	storage: [1024]linux.IO_Vec
	moves: [1024][24]byte = ---
	prefix := transmute([]byte)Frame_Origin
	storage[0] = {raw_data(prefix), uint(len(prefix))}
	count := 1
	cursor := 0
	rows := bit_array.make_iterator(&e.emit_rows)
	for i, ok := bit_array.iterate_by_set(&rows); ok; i, ok = bit_array.iterate_by_set(&rows) {
		for bytes in ([2][]byte{row_move(moves[count][:], i - cursor), e.rows[i].bytes}) {
			if len(bytes) == 0 do continue
			storage[count] = {raw_data(bytes), uint(len(bytes))}
			count += 1
			if count == len(storage) {
				if write_vectors(1, storage[:count], e) != nil do return
				count = 0
			}
		}
		cursor = i
	}
	if count != 0 do write_vectors(1, storage[:count], e)
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
