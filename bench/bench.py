#!/usr/bin/env python3
"""Benchmark the Odin port (otfx) against the Rust ttfx.

Both sides run their real user-facing command with pacing disabled
(--frame-rate 0), so this measures render throughput, not sleep().
Canvas geometry is pinned to 200x50 with input covering the canvas.

Short effects are automatically batched until each timing sample spans at
least BENCH_MIN_SECONDS (default: 2). This avoids reporting process-wait
granularity as effect performance.

Usage: bench/bench.py [repeats] [effect ...]
"""

import os
import math
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ODIN = ROOT / "otfx"
RUST = ROOT / "third_party/ttfx/target/release/ttfx"

REPEATS = int(sys.argv[1]) if len(sys.argv) > 1 else 5
MIN_SAMPLE_SECONDS = float(os.environ.get("BENCH_MIN_SECONDS", "2"))
COLS, LINES = 200, 50

ENV = {**os.environ, "COLUMNS": str(COLS), "LINES": str(LINES)}

EFFECTS = [
    "beams", "binarypath", "blackhole", "bouncyballs", "bubbles", "burn",
    "colorshift", "crumble", "decrypt", "errorcorrect", "expand", "fireworks",
    "highlight", "laseretch", "matrix", "middleout", "orbittingvolley", "overflow",
    "pour", "print", "rain", "randomsequence", "rings", "scattered", "slice",
    "slide", "smoke", "spotlights", "spray", "swarm", "sweep", "synthgrid",
    "unstable", "vhstape", "waves", "wipe",
    "thunderstorm",
]

# Matrix and Thunderstorm are wall-clock-gated. Their elapsed-time ratios are
# not normalized throughput comparisons; they need a shared virtual-clock
# harness. Keep their real CLI runs short enough for the all-effect sweep.
EXTRA = {
    "matrix": ["--rain-time", "5"],
    "thunderstorm": ["--storm-time", "1"],
}


def make_input() -> bytes:
    rows, width = LINES - 4, COLS - 10
    filler = "the quick brown fox jumps over the lazy dog"
    lines = [f"benchmark line {i:03d} - {filler}" for i in range(rows)]
    lines = [(l * (width // len(l) + 1))[:width] for l in lines]
    return "\n".join(lines).encode()


def run_once(cmd: list[str], data: bytes) -> float:
    t = time.monotonic()
    subprocess.run(cmd, input=data, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, env=ENV, timeout=600,
                   check=True)
    return time.monotonic() - t


def best_of(cmd: list[str], data: bytes) -> tuple[float, int]:
    probe = run_once(cmd, data)
    batch_count = max(1, math.ceil(MIN_SAMPLE_SECONDS / probe))
    times = []
    for _ in range(REPEATS):
        t = time.monotonic()
        for _ in range(batch_count):
            subprocess.run(cmd, input=data, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, env=ENV, timeout=600,
                           check=True)
        times.append((time.monotonic() - t) * 1000 / batch_count)
    return min(times), batch_count


def frame_count(binary: Path, effect: str, data: bytes) -> int:
    # both binaries in normal mode; every frame starts with DEC restore+save
    cmd = [str(binary), "--seed", "1", "--frame-rate", "0", effect] + EXTRA.get(effect, [])
    r = subprocess.run(cmd, input=data, capture_output=True, env=ENV, timeout=600)
    return r.stdout.count(b"\x1b8\x1b7")


def startup(binary: Path) -> float:
    data = b"x\n"
    elapsed, _ = best_of([str(binary), "--frame-rate", "0", "slide"], data)
    return elapsed


def main() -> int:
    data = make_input()
    if not ODIN.exists() or not RUST.exists():
        print("build both binaries first: odin build src -o:speed -out:otfx && cargo build --release")
        return 1

    selected = sys.argv[2:] if len(sys.argv) > 2 else EFFECTS
    unknown = [fx for fx in selected if fx not in EFFECTS]
    if unknown:
        print("unknown effect(s):", " ".join(unknown), file=sys.stderr)
        return 2

    print(
        f"canvas {COLS}x{LINES}, best of {REPEATS}, "
        f">={MIN_SAMPLE_SECONDS:g}s per sample, frame pacing disabled\n"
    )
    print(f"{'effect':<16}{'ttfx rust':>12}{'otfx odin':>12}{'rust xN':>9}{'odin xN':>9}{'frames rust':>12}{'frames odin':>12}{'speedup':>9}")
    print("-" * 91)

    for fx in selected:
        cmd = lambda b: [str(b), "--seed", "1", "--frame-rate", "0", fx] + EXTRA.get(fx, [])
        tr, nr = best_of(cmd(RUST), data)
        to, no = best_of(cmd(ODIN), data)
        fr = frame_count(RUST, fx, data)
        fo = frame_count(ODIN, fx, data)
        speedup = tr / to
        print(f"{fx:<16}{tr:>10.1f}ms{to:>10.1f}ms{nr:>9}{no:>9}{fr:>12}{fo:>12}{speedup:>8.2f}x")

    ts, to = startup(RUST), startup(ODIN)
    print(f"{'startup (slide, x)':<16}{ts:>10.1f}ms{to:>10.1f}ms{'':>42}{ts / to:>8.2f}x")
    print("-" * 91)

    rust_size = RUST.stat().st_size / 1024
    odin_size = ODIN.stat().st_size / 1024
    print(f"\nbinary size: rust {rust_size:.0f} KiB, odin {odin_size:.0f} KiB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
