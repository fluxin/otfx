# Reverse stack search and Middleout update order

2026-09-26. Isolated controls against checkpoint `3850833c`; no production
source changes. Both controls preserve ascending `(layer, particle ID)` cell
order, ordered removal, and the existing top/bottom fast paths.

1. Replace the remaining binary searches with reverse linear searches.
2. Independently retain binary search and visit Middleout's moving particles
   in reverse input order (descending input particle ID).

## Full CLI measurements

Native Odin `-o:speed -microarch:native -debug`, assertions enabled, CPU 2,
terminal 200x50, input 190x46, seed 1, frame-rate zero, stdout `/dev/null`.
Three samples, minimum 0.5 seconds per sample. No builds, instrumentation, or
capture jobs ran during timings. The benchmark's `rust` label denotes the
frozen before Odin binary in these A/B logs; ASM was not measured.

| Control | Effect | Before wall | After wall | Before/after mean CPU | Before/after peak RSS KiB | Frames |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Reverse linear search | Middleout | 25.9 ms | 38.6 ms | 25.8 / 38.5 ms | 11776 / 11776 | 235 / 235 |
| Reverse linear search | Expand | 24.5 ms | 26.0 ms | 24.3 / 25.9 ms | 10816 / 10816 | 302 / 302 |
| Reverse linear search | Slide | 20.8 ms | 20.7 ms | 20.7 / 20.6 ms | 10240 / 12032 | 375 / 375 |
| Reverse move order | Middleout | 25.9 ms | 26.3 ms | 25.8 / 26.3 ms | 11772 / 11776 | 235 / 235 |

Neither control is a demonstrated improvement. Reverse linear search makes
Middleout about 49% slower and Expand about 6% slower. Reversing Middleout
updates alone is slightly slower in this screen; it is not an accepted change.

## Why sorted does not imply popping

The renderer sorts by painter priority, not departure time. Middleout moves
groups sharing a coordinate/motion calculation. Higher-priority stationary
particles can remain above a departing particle. A destination may also still
contain particles that have not moved when the current particle arrives.

Separate instrumented binaries counted Middleout's cell operations:

| Operation | Input order | Reverse input order |
| --- | ---: | ---: |
| Top removals (`pop`) | 5,514 | 13,469 |
| Bottom removals | 11,975 | 5,452 |
| Interior removal searches | 400,329 | 398,897 |
| Top/empty insertions (`append`) | 91,909 | 32,533 |
| Bottom insertions | 20,322 | 80,344 |
| Interior insertion searches | 312,671 | 312,025 |

Top removals rise from 1.3% to 3.2%, but append insertions decline sharply.
For baseline interior removal searches, mean distance from the top is 163.9
entries and only 18.3% are within eight entries; maximum searched stack size
is 6,900. Interior insertion searches average 132.2 entries below the top.
These counts describe this fixture, not all configurations or effects.

Changing stack priority itself to departure order could increase pops, but
would also change which glyph is visible while particles overlap. Reversing
update traversal avoids that semantic change and was measured separately.

## Validation and evidence

Both controls match the baseline byte-for-byte on 12 Middleout captures:
vertical/horizontal, speeds 0.6/100, and Ignore/Always/Dynamic input colors.
All targeted benchmark frame counts also match. These rejected screens did
not run the full 35-effect acceptance suite or the full regression tests.

Sources, uninstrumented binaries, instrumented binaries, logs, counters, and
capture results remain under `/tmp/otfx-reverse-stack-20260926/`.
