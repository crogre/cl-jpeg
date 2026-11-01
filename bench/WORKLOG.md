# Decoder memory/speed experiments: plan and worklog

Branch `low-memory-experiments`, started from `b3fc122` (branch
`decoder-performance`), where cl-jpeg is at parity with stb_image in
speed and memory. Baseline numbers are in `RESULTS.md`.

Goal: lower memory use below stb_image, and gain speed where possible,
without making the code messy. Each experiment is measured with the
tools in this directory and must keep all correctness checks passing:

- `check.lisp`: 354 images against libjpeg's djpeg (max diff 6)
- `idct-check.lisp`: NEON vs scalar IDCT on random blocks (exact)
- `simd-check.lisp`: NEON vs scalar color conversion (exact)
- speed: `run.sh <label>`; memory: `alloc.lisp` (cl-jpeg) and `stb_mem`

Experiments are done one after the other in this session (they all
touch the same hot code, so parallel work would conflict).

Branches, for comparing implementations afterwards:

| experiment | branch | based on |
|---|---|---|
| 1. MCU rows | `exp/1-mcu-rows` | `3b9e4c6` |
| 2. input + Huffman | `exp/2-input-huffman` | `3b9e4c6` |
| 3. sparse IDCT | `exp/3-sparse-idct` | `3b9e4c6` |
| 4. progressive bands | `exp/4-progressive-bands` | `exp/1-mcu-rows` (reuses its per-row output) |
| 5. optional features | `exp/5-*` | decided later |

Experiment branches hold only code; this worklog and the results live
on `low-memory-experiments`.

## Reference (b3fc122, 2048x2048 unless noted)

| image | stb ms | cl-jpeg ms | stb MB | cl-jpeg MB |
|---|---|---|---|---|
| base420 | 25.3 | 20.6 | 18.9 | 19.0 |
| base444 | 67.2 | 67.0 | 25.2 | 25.3 |
| gray | 15.2 | 14.4 | 8.4 | 8.4 |
| prog420 | 50.2 | 57.6 | 31.5 | 31.6 |
| prog420 4000x3000 | 142.4 | 171.0 | 90.2 | 90.4 |

The default `decode-image` (byte-by-byte file stream) is 12-20% slower
than these in-memory numbers.

## Plan

### 1. Decode baseline images one MCU row at a time
Planes hold one MCU row per component instead of the whole image; after
each MCU row, the color conversion/interleave pass writes it to the
output (as libjpeg's iMCU-row buffering does). Sequential files with one
scan per component keep whole-image planes as a fallback.
Expected: baseline memory ~ output size (base420 19.0 -> ~12.7 MB,
base444 25.3 -> ~12.7, gray 8.4 -> ~4.3); some speed from cache locality.

### 2. Faster byte input and Huffman decoding
a. Read file streams through a chunk buffer (16-64 KB) instead of
   `read-byte` per byte; no need to hold the whole file.
b. libjpeg-turbo's `decode_mcu_fast` idea: when enough data remains and
   no restart is due, decode with the bit buffer in local variables and
   direct array access, checking for markers once per block/MCU.
Expected: default `decode-image` 12-20% faster; entropy decoding
15-25% faster (estimate).

### 3. Sparse and DC-only IDCT
Huffman decoding records the last nonzero coefficient index; DC-only
blocks become a constant fill, low-frequency-only blocks take a cheaper
path (libjpeg-turbo's NEON IDCT has regular/sparse/DC-only paths); only
the coefficients set are cleared. Add a smooth test image, since the
noisy benchmark images have few such blocks.

### 4. Band-by-band progressive decoding
Pre-parse the scans (offset, Huffman tables, parameters, restart
interval), then decode one MCU-row band at a time, resuming each scan's
saved cursor (position, bit buffer, EOB run, DC predictors). Coefficient
memory drops to one band. Needs random access to the input (in-memory
source or `file-position`). Patent status (US7469067, US7894681)
checked by the project owner: OK to use.
Expected: prog420 31.6 -> ~13 MB (2048x2048), 90 -> ~37 MB (12 MP);
probably faster (no full-image coefficient pass, better locality).

### 5. Optional features
- Reduced-size decoding (`:scale` 1/2, 1/4, 1/8), keeping only the
  needed coefficients for progressive images (lowzag's idea).
- Row callback API so callers need not hold the full output.
- Threads: Huffman decoding and IDCT/color conversion pipelined per MCU
  row.

## Worklog

(entries are added as experiments complete)

### 2026-11-01 — Experiment 1: MCU rows — done (`exp/1-mcu-rows`, 148bd79)

Planes hold one band (MCU row) when the first scan of a sequential frame
covers all components (it is then the only scan). `map-scan-blocks`
calls a band-done hook after the last block of each band, which writes
that band to the output (`output-band` -> `output-rows`). One-scan-per-
component sequential frames and progressive frames keep whole-image
planes. Column maps are now prepared once per frame.

| image | stb MB | before MB | exp1 MB |
|---|---|---|---|
| base420 2048 | 18.9 | 19.0 | **12.7** |
| base444 2048 | 25.2 | 25.3 | **12.8** |
| gray 2048 | 8.4 | 8.4 | **4.3** |
| base420 4000x3000 | 54.1 | — | **36.3** |
| prog420 2048 | 31.5 | 31.6 | 31.6 (unchanged, see exp 4) |

Speed: unchanged within noise (two runs; base420 2048 21.0-21.6 ms vs
20.6, base444 66.7-67.3 vs 67.0, gray 14.6 vs 14.4). The expected cache
locality gain did not show up; the planes were apparently not a
bottleneck. All checks pass (354/354 images, SIMD color exact).

Found: a truncated file signals END-OF-FILE (from the byte reader), on
the base branch too. To handle in the robustness work.
