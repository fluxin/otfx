# Scattered and Fireworks revalidation and remaining costs

2026-09-26. No production code changes. Current `src` still matches the frozen final source from [shared motion](shared-motion.md). Both frozen binary hashes match the previous report. The reference for the optimization comparison is compaction-only; the candidate includes shared Scattered samples and Fireworks shell launch motion.

## Alternating-order timings

Six paired batches per effect, alternating before/after then after/before. Each Scattered batch runs 16 complete CLIs; each Fireworks batch runs eight. Two warmups per binary/effect precede measurements. Same dense input, seed 1, CPU 2, terminal 200x50, frame-rate 0, stdout `/dev/null`, native speed/debug binaries. No concurrent builds, tests or profiles were launched by this agent during timing. External activity cannot be ruled out.

Medians below are over six batch averages, not minima. All six pairs favor the candidate for each effect. [Every batch](shared-motion-revalidation.tsv).

| Effect | Before wall ms | After wall ms | Reduction | Before CPU ms | After CPU ms | After batch wall range ms |
|---|---:|---:|---:|---:|---:|---:|
| Scattered | 45.875 | 31.113 | 32.18% | 45.604 | 30.875 | 31.066–31.194 |
| Fireworks | 72.397 | 65.888 | 8.99% | 72.049 | 65.559 | 65.786–65.945 |

This confirms the two effect improvements. It does not replace or revalidate the entire 35-effect aggregate. The recorded ASM times remain 24.8 ms for Scattered and 62.5 ms for Fireworks; no new ASM timing was performed. Comparing those historical numbers to these medians leaves approximately 6.3 ms and 3.4 ms respectively; the CLI launcher and summary statistic also differ slightly from the original benchmark.

The alternating harness uses Python `Popen`/`wait4`. Its peak RSS includes a launcher floor around 17 MiB, so that RSS is retained in the raw data but not interpreted as effect memory usage. A separate rerun of the native Odin benchmark gives:

| Effect | Native best wall before/after ms | Native mean CPU before/after ms | Native peak RSS before/after KiB |
|---|---:|---:|---:|
| Scattered | 45.8 / 31.0 | 45.6 / 30.9 | 9992 / 10092 |
| Fireworks | 72.3 / 65.7 | 72.1 / 65.5 | 16216 / 16264 |

Native frame counts remain 420/420 and 1516/1516. Repeated 84/84 option/seed/color captures and both full dense captures are byte-identical. Dense hashes and lengths match the earlier report. The test suite was not rerun because neither production code nor tests changed in this pass; the previous 82/86 result and four known allocation failures remain the applicable test result.

## Fresh profiles of the optimized binary

`perf record -e cycles:u -F 999 --call-graph dwarf,8192`, 130 complete Scattered runs then 60 Fireworks runs, sequentially on CPU 2. Approximately 3,000 samples each; zero lost samples. Shares below are exclusive sampled user-cycle attribution, including compiler inline attribution. Parent and child percentages must not be added together; kernel work is excluded. Check-site attribution under `bounds_check_error` does not indicate executed errors. These are priorities, not measured savings for unimplemented changes.

Scattered:

- `cell_remove` 10.82%, `cell_insert` 7.85%, `cell_compact` 4.44%: 23.11% in these three membership sites alone. Removal no longer binary-searches; it updates cell membership/top, dirtiness and the deferred-compaction list. Sorted arrivals and final filtering remain necessary under the retained design. A linked-list rewrite is not implied by this result.
- Effect loop self 16.20%; additional inline queue work 3.87%, position equality 2.70%, line interpolation 1.81%, coordinate rounding 1.30%. The next effect-side opportunity is sharing other values derived solely from a duration/tick, such as the color-sample index; the rounding site itself is only about 1%, so that alone cannot close the remaining gap.
- Render appearance lookup 6.62%; raw copy attribution 5.36%, of which 3.93% is explicitly attributed through packet writing. Moving winners still need valid destination-cell bytes even when their appearance is unchanged. This is a shared renderer cost, not evidence that unchanged colors should dirty every particle.
- All libm symbols together are now 2.28% of samples. Shared easing removed the earlier dominant repeated math, but remaining interpolation and cell work still run per active particle.

Fireworks:

- Effect update self plus its inline work is 61.05%. Within that, appearance equality accounts for 6.08%, placement logic 4.64%, queueing 4.17%, quartic easing 6.42%, and quadratic-Bezier interpolation 3.21%. These inline shares are already included in the 61.05%.
- The immediate effect-side candidate is phase/sample publication: install visibility/layer and launch glyph when a shell starts; restore the input glyph on transition to the burst; publish a color only when its sample changes. Currently every active tick goes through `set_placement`, `set_symbol` and `set_appearance`, including ten-tick fall-color holds. Keep the setter guards; avoid reaching them for known holds.
- Quartic return easing and Bezier positions are the remaining math. Shared launch position did not remove these per-particle paths. Any further grouping must include the complete phase clock/duration inputs; equal easing names alone do not imply equal samples.
- Renderer membership sites: insertion 4.61%, compaction 3.91%, removal 3.23%. Raw copy attribution is 4.54%, explicitly through packet writing 3.64%; render appearance lookup is 1.58%.
- All libm symbols together are now 0.03%. Replacing the math library is not a useful direction for this remaining profile; the quartic operation is inlined arithmetic.

The common next target is the amount of per-particle publication and cell-membership work, with packet preparation behind it. Fireworks has clear phase/hold submissions to eliminate first. Scattered already guards held foreground samples, so its main remaining target is membership/renderer work. No additional optimization has been implemented in this validation pass.

Artifacts: `/tmp/otfx-motion-revalidation-20260926/` contains the alternating harness, all 288 measured individual runs, batch summaries, native benchmark log, both perf data/report pairs, library totals and repeated captures. Frozen binaries remain under `/tmp/otfx-outlier-work-20260926/`. No source edits or commits were made by this pass; only this report and measurement tables were added/linked.
