"""Capture original Python and production Odin cells on the same gallery fixture.

Run with uv; no third-party Python dependencies. Images sample each animation at
12 fractions of its own duration. They are review aids, never parity assertions.
"""

import argparse
import html
import importlib
import json
from pathlib import Path
import random
import re
import zlib
import subprocess
import sys
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "third_party/terminaltexteffects"))
import terminaltexteffects.effects as effects


def frame_cells(frame):
    """Decode full Python frames (SGR and newlines only, no cursor emulation)."""
    cells = []
    x = y = 0
    fg = bg = ""
    position = 0
    while position < len(frame):
        symbol = frame[position]
        if symbol == "\x1b":
            match = re.match(r"\x1b\[([0-9;]*)m", frame[position:])
            if not match:
                raise ValueError("unexpected non-SGR escape in Python frame")
            codes = [int(code or 0) for code in match[1].split(";")]
            i = 0
            while i < len(codes):
                code = codes[i]
                if code == 0:
                    fg = bg = ""
                elif code in (38, 48):
                    if codes[i + 1] != 2:
                        raise ValueError("gallery capture requires RGB output")
                    color = "#%02x%02x%02x" % tuple(codes[i + 2:i + 5])
                    if code == 38:
                        fg = color
                    else:
                        bg = color
                    i += 4
                elif code == 39:
                    fg = ""
                elif code == 49:
                    bg = ""
                elif code not in (1, 2, 22):
                    raise ValueError(f"unsupported SGR {code}")
                i += 1
            position += match.end()
            continue
        if symbol == "\n":
            x, y = 0, y + 1
        else:
            if symbol != " " or bg:
                cells.append(dict(x=x, y=y, symbol=symbol, fg=fg, bg=bg))
            x += 1
        position += 1
    return cells


def capture_python(cls, text, overrides):
    module = importlib.import_module(cls.__module__)
    clock = [0]
    original_time = getattr(module, "time", None)
    if original_time is not None:
        module.time = SimpleNamespace(time=lambda: clock[0] / 60,
                                      monotonic=lambda: clock[0] / 60)
    try:
        random.seed(3)
        effect = cls(text)
        cfg = effect.terminal_config
        cfg.canvas_width, cfg.canvas_height = 84, 13
        cfg.anchor_canvas = cfg.anchor_text = "c"
        cfg.ignore_terminal_dimensions = True
        cfg.frame_rate = 0
        for name, value in overrides.items():
            setattr(effect.effect_config, name, value)
        # Capture one actual run. In particular, Swarm's set iteration can
        # change its random progression between two reconstructions.
        frames = []
        for tick, frame in enumerate(effect):
            if tick >= 20_000:
                raise RuntimeError("20,000-frame completion limit reached")
            frames.append(zlib.compress(frame.encode(), level=1))
            clock[0] += 1
        total = len(frames)
        wanted = sorted({i * (total - 1) // 11 for i in range(12)})
        snapshots = [dict(tick=tick, cells=frame_cells(zlib.decompress(frames[tick]).decode()))
                     for tick in wanted] if total else []
        return dict(effect=cls.__name__.lower(), total=total, frames=snapshots)
    finally:
        if original_time is not None:
            module.time = original_time


def sheet(name, captures, destination):
    # Shared font, cell geometry, and shade rendering for both implementations.
    width, height = 504, 130
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{2 * width}" height="{12 * (height + 24)}">',
           '<rect width="100%" height="100%" fill="#12121a"/>']
    for column, (label, capture) in enumerate(zip(("Python", "Odin"), captures)):
        for row, frame in enumerate(capture["frames"]):
            dx, dy = column * width, row * (height + 24)
            svg.append(f'<text x="{dx + 4}" y="{dy + 14}" font-size="12" fill="white">'
                       f'{name} {label}: frame {frame["tick"] + 1}/{capture["total"]}</text>')
            for cell in frame["cells"]:
                x, y = dx + cell["x"] * 6, dy + 24 + cell["y"] * 10
                fg, bg = cell["fg"] or "#c8c8d0", cell["bg"] or "#12121a"
                if cell["bg"]:
                    svg.append(f'<rect x="{x}" y="{y}" width="6" height="10" fill="{bg}"/>')
                symbol = cell["symbol"]
                if symbol in "░▒▓█" and symbol:
                    opacity = {"░": .25, "▒": .5, "▓": .75, "█": 1}[symbol]
                    svg.append(f'<rect x="{x}" y="{y}" width="6" height="10" fill="{fg}" opacity="{opacity}"/>')
                elif symbol.strip():
                    svg.append(f'<text x="{x}" y="{y + 8}" font-family="DejaVu Sans Mono" '
                               f'font-size="10" fill="{fg}">{html.escape(symbol)}</text>')
    svg.append('</svg>')
    destination.write_text("\n".join(svg))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--odin", required=True, type=Path)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("effects", nargs="*")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    text = args.input.read_text().rstrip("\n")
    classes = {name.lower(): cls for name, cls in vars(effects).items()
               if isinstance(cls, type) and cls.__module__.startswith("terminaltexteffects.effects.")}
    results = []
    for name in args.effects or sorted(classes):
        overrides = {"error_pairs": .5} if name == "errorcorrect" else {}
        options = ["--error-pairs", "0.5"] if overrides else []
        try:
            output = args.out / f"{name}-odin.json"
            subprocess.run([str(args.odin), name, str(args.input), str(output), *options], check=True)
            odin = json.loads(output.read_text())
            python = capture_python(classes[name], text, overrides)
            (args.out / f"{name}-python.json").write_text(json.dumps(python))
            sheet(name, (python, odin), args.out / f"{name}.svg")
            row = dict(effect=name, python_frames=python["total"], odin_frames=odin["total"])
        except Exception as error:
            row = dict(effect=name, error=str(error))
        results.append(row)
        print(json.dumps(row), flush=True)
        (args.out / "summary.json").write_text(json.dumps(results, indent=2))
    links = [f'<li><a href="{html.escape(row["effect"])}.svg">'
             f'{html.escape(row["effect"])}</a></li>'
             for row in results if "error" not in row]
    (args.out / "index.html").write_text(
        '<!doctype html><meta charset="utf-8"><title>Python / Odin review</title>'
        '<h1>Python / Odin review</h1><p>Twelve samples per run; '
        'random paths and durations may differ.</p><ul>' + "\n".join(links) + '</ul>')
    if any("error" in row for row in results):
        sys.exit(1)


if __name__ == "__main__":
    main()
