package engine

import "core:os"
import "core:sys/linux"

// Contiguous capture is an explicit consumer, not a second renderer.
frame_bytes :: proc(e: ^Engine) -> []byte {
	clear(&e.capture_buf)
	for part in e.output_parts do append(&e.capture_buf, ..part)
	return e.capture_buf[:]
}

// The syscall boundary is the only consumer needing native iovec descriptors.
// A short write may end inside any slice; retry from that exact byte.
write_vectors :: proc(fd: linux.Fd, vectors: []linux.IO_Vec) -> linux.Errno {
	remaining := vectors
	for len(remaining) != 0 {
		if remaining[0].len == 0 {
			remaining = remaining[1:]
			continue
		}
		count, err := linux.writev(fd, remaining[:min(len(remaining), 1024)])
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
	storage: [1024]linux.IO_Vec
	prefix := transmute([]byte)Frame_Origin
	storage[0] = {raw_data(prefix), uint(len(prefix))}
	count := 1
	for bytes in e.output_parts {
		storage[count] = {raw_data(bytes), uint(len(bytes))}
		count += 1
		if count == len(storage) {
			if write_vectors(1, storage[:count]) != nil do return
			count = 0
		}
	}
	if count != 0 do write_vectors(1, storage[:count])
	os.flush(os.stdout)
}
