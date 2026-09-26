from pathlib import Path
import subprocess, os, hashlib, tempfile, json, argparse

parser = argparse.ArgumentParser(description="Compare 222 deterministic otfx CLI captures byte for byte.")
parser.add_argument("before", type=Path)
parser.add_argument("after", type=Path)
parser.add_argument("--output", type=Path, help="Optional JSON result file")
config = parser.parse_args()
binaries = (config.before.resolve(), config.after.resolve())
source = Path(__file__).resolve().parent.parent / "src/effects"
effects = sorted(p.stem for p in source.glob('*.odin') if p.stem != 'effect')
env = {**os.environ, 'COLUMNS':'80', 'LINES':'24'}
fixtures = [
    ('plain', b'Retained raster\nA B C D\nFinal row', []),
    ('no-color', b'ABC\nDEF', ['--no-color']),
    ('sgr-always', b'\x1b[31;44mABC\x1b[0m DE\n\x1b[38;2;2;90;240mF G\x1b[0m', ['--existing-color-handling','always']),
    ('sgr-dynamic', b'\x1b[31mABC\x1b[0m DE\nF G', ['--existing-color-handling','dynamic']),
    ('xterm', 'A░B\n█ ┃ ▉'.encode(), ['--xterm-colors']),
    ('clipped', b'ABC DEFGHIJKLMN\n0123456789\nFOUR\nFIVE', ['--canvas-width','7','--canvas-height','3','--anchor-text','c','--wrap-text']),
]
results=[]
for fixture, data, options in fixtures:
    for effect in effects:
        args=['--seed','42','--frame-rate','0','--virtual-clock','--canvas-width','40','--canvas-height','12','--ignore-terminal-dimensions',*options,effect]
        if effect=='matrix': args+=['--rain-time','1']
        if effect=='thunderstorm': args+=['--storm-time','1']
        outputs=[]
        for binary in binaries:
            with tempfile.TemporaryFile() as f:
                r=subprocess.run([str(binary),*args],input=data,stdout=f,stderr=subprocess.PIPE,env=env,timeout=30)
                f.seek(0)
                h=hashlib.file_digest(f,'sha256').hexdigest()
                outputs.append((r.returncode, f.tell(), h, r.stderr.decode(errors='replace')))
        ok=outputs[0]==outputs[1] and outputs[0][0]==0
        results.append(dict(fixture=fixture,effect=effect,ok=ok,outputs=outputs))
        print(f'{fixture} {effect}: {"PASS" if ok else "FAIL"}',flush=True)
    if config.output:
        config.output.write_text(json.dumps(results, indent=2))
print(f'{sum(x["ok"] for x in results)}/{len(results)} exact captures')
raise SystemExit(any(not x['ok'] for x in results))
