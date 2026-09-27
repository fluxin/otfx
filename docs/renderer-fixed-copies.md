# Fixed packet writes and cell removal — 2026-09-26

Retained: two small changes in `src/engine/codes.odin`. The 43-byte appearance
copy runs inside the styled branch, where its length is constant. Glyph writes
copy all four bytes returned by `utf8.encode_rune`; the existing reset and NUL
padding overwrite unused bytes. The cell layout, emitted bytes and logical
glyph API do not change. No fields, caches, queues or allocation paths were added.

Cell glyph bytes already live in `canvas_bytes`, borrowed through each cell's
slice. Clean cells are not repatched. Dirty cells still encode their winning
glyph, even when the change was only to color. This change reduces copy overhead;
it does not remove cell patching or pre-render the animation.

Ordered removal is retained at the user's direction. Swap removal is
semantically valid because winners use `(layer, particle ID)`, but measured
performance rejected it. It disrupts the order searched by subsequent removals:

| Effect | Ordered search comparisons | Swap search comparisons |
| --- | ---: | ---: |
| Fireworks | 1,203,781 | 22,719,871 |
| Middleout | 29,926,912 | 46,366,040 |
| Swarm | 1,622,075 | 1,793,434 |

These exact counters come from isolated diagnostic source copies. They were
not added to production. Repeated swap-only measurements slowed Fireworks
84.2 -> 87.9 ms and Middleout 27.9 -> 29.3 ms. The combined packet/swap variant
showed the same regressions. Source and binary variants remain saved.

## Retained packet-only result

| Metric | Before | Fixed copies |
| --- | ---: | ---: |
| 35-effect mean best wall | 46.409 ms | 45.703 ms |
| 35-effect mean wall | 46.606 ms | 45.923 ms |
| 35-effect mean CPU | 46.420 ms | 45.746 ms |
| Mean per-effect peak RSS | 13,807 KiB | 13,711 KiB |
| Burn best wall | 46.3 ms | 43.4 ms |
| Swarm best wall | 127.4 ms | 125.4 ms |

Aggregate best wall improved 1.52%; CPU improved 1.45%. This is a small screen
result, not a large architectural gain. No effect exceeded a 2% best-wall
regression in the retained variant. All 35 frame counts match. Full results:
[renderer-fixed-copies.tsv](renderer-fixed-copies.tsv).

The before binary includes the earlier, still-uncommitted action-batch draft.
That draft was not discarded or modified in this experiment. ASM was not rerun.
Its cached Swarm result is 95.3 ms for 5,041 frames, versus our 4,312; the full
effect timings do not represent identical frame work.

Both native binaries use `-o:speed -microarch:native -debug`, seed 1, terminal
200x50, input 190x46, frame rate zero, stdout `/dev/null`, CPU 2, and two batched
samples of at least 0.3 seconds. Confirmations of the two swap regressions used
three samples. Only the shared renderer changes required full-suite screens;
unchanged ASM was reused. No compilation, tests or profiling overlapped timing.
Matrix/Thunderstorm are excluded from the finite-effect throughput mean.

Validation: `odin check src`; 222/222 exact captures for the retained packet
binary; 70 unit tests with the same four pre-existing allocation failures.
All 37 effects pass four-frame smoke; parity reports 13 matches, 24 existing
diagnostic differences, and zero failures.
Existing glyph/padding coverage was extended to include two- and three-byte
UTF-8 alongside ASCII, four-byte and empty glyphs. No test was weakened.

Artifacts: `/tmp/otfx-render-simple-20260926`. `packet` is the retained binary;
`unordered` and `after` are the rejected swap-only and combined variants.
No commits were made. The root `otfx` executable was not replaced.

```sh
BENCH_MIN_SECONDS=0.3 taskset -c 2 \
  /tmp/otfx-render-simple-20260926/bench-packet 2 swarm
```

Harness labels `rust` and `odin` mean frozen before/after Odin binaries here.
SHA-256 before: `e450e08a6c3649ecec092157eb91694bbd4a16713abcffbbf0344b5e0ac8a969`.
Retained: `74458cbbde459df04409bb1fdc0cf0203b20ae587a644dd6935b19a105925568`.
