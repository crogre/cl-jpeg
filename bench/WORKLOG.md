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
| 1. MCU rows | `exp/1-mcu-rows` | `648f502` |
| 2. input + Huffman | `exp/2-input-huffman` | `648f502` |
| 3. sparse IDCT | `exp/3-sparse-idct` | `648f502` |
| 4. progressive bands | `exp/4-progressive-bands` | `exp/1-mcu-rows` (reuses its per-band output) |
| 5. combined + row callback + scaling | `exp/5-combined` | `exp/4-progressive-bands` + merges of 2 and 3 |

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

### 2026-11-01 — Experiment 1: MCU rows — done (`exp/1-mcu-rows`, 4b42564)

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

### 2026-11-01 — Experiment 2: input + Huffman — done (`exp/2-input-huffman`, f7efc59, 6cc27a8)

2a (f7efc59): `read-jpeg-byte` reads from a buffer in the descriptor instead
of calling a closure per byte. Source cache = buffer; file streams are
read in 32 KB chunks and repositioned after the data used at the end
(checked: two concatenated JPEGs decode from one stream); other streams
byte by byte. Default `decode-image` is now as fast as in-memory
decoding (base444 2048: 75 -> 68 ms). In-memory speed unchanged.

2b (6cc27a8): `with-local-bits` keeps the bit buffer in locals for a whole
block (libjpeg-turbo's fast path idea), in the sequential block decoder
and all four progressive decoders. The refinement correction helper was
a closure call per bit and is now a macro, which explains much of the
progressive gain.

| image (2048x2048) | stb ms | before ms | exp2 ms | vs stb |
|---|---|---|---|---|
| base420 | 25.3 | 20.6 | 20.2 | 0.80x |
| base444 | 67.2 | 67.0 | 59.3 | 0.88x |
| gray | 15.2 | 14.4 | 13.5 | 0.88x |
| prog420 | 50.2 | 57.6 | **41.9** | 0.83x |
| prog420 4000x3000 | 142.4 | 171.0 | 121.6 | 0.85x |

Every variant is now faster than scalar stb_image. Memory unchanged
(plus a 32 KB chunk buffer when reading file streams). All checks pass.
Also bounded the coefficient index in `decode-ac-first` against corrupt
data.

(Commit ids above are after rebasing the experiment branches onto
`648f502`, which added smooth 4:2:0 benchmark images.)

### 2026-11-01 — Experiment 3: sparse IDCT — done (`exp/3-sparse-idct`, e96dbb6)

The block decoders return the zigzag index of the last coefficient set.
DC-only blocks become a constant fill (same result as the transform);
on NEON, blocks with coefficients only in the top left 4x4 (zigzag index
<= 9) use a sparse variant generated from the same macros:
`llm-idct-1d` now folds literal zero inputs at expansion time, and the
NEON macro skips the right half of the column pass and zero tiles.
Blocks are cleared only where coefficients were set when sparse
(`fill` otherwise: scattered clearing of dense blocks cost 5-7% on the
noisy images in a first version).

| image (2048x2048) | stb ms | base ms | exp3 ms |
|---|---|---|---|
| smooth420 | 16.5 | 12.3 | **10.1** |
| smooth420 4000x3000 | 46.5 | 35.9 | **25.5** |
| base420 | 25.2 | 20.3 | 20.8 |
| base444 | 66.3 | 65.6 | 65.0 |
| gray | 15.1 | 14.9 | 14.1 |
| prog420 | 49.6 | 58.7 | 59.5 |

Smooth images (typical of photos with sky, skin, out-of-focus areas)
gain 17-29%; noisy ones are unchanged within noise. Memory unchanged.
`idct-check.lisp` now covers DC-only and top-left-only blocks (300000
random blocks, exact). All checks pass.

Note on method: all tests run in fresh SBCL processes (write, compile,
test), since the hot code is inline functions and macros that a REPL
would leave stale in their callers.

### 2026-11-01 — Experiment 4: progressive bands — done (`exp/4-progressive-bands`, 643f601)

Based on `exp/1-mcu-rows` (uses its strip planes and `output-band`).
`read-progressive-scans` reads all scans up to EOI, keeping per scan a
cursor with its header, copies of the Huffman tables in effect (DHT can
change between scans), its restart interval and its entropy-coded data
(copied into one buffer, terminating marker kept so the bit reader
stops). Each band is then decoded from every scan in turn
(`advance-cursor`: resumes position, bit reader, EOB run, DC predictors;
handles RSTn at interval ends and resyncs on early ones), then
dequantized/IDCT'd into the strip planes and output. Coefficient
buffers are one band high. All 354 images pass on the first run,
including progressive files with every restart setting.

| image | stb MB | before MB | exp4 MB |
|---|---|---|---|
| prog420 2048 | 31.5 | 31.6 | **14.9** |
| prog420 4000x3000 | 90.2 | 90.4 | **40.6** |

(Allocation measured; part of the excess over the 12.6/36 MB output is
garbage from growing the scan data buffer by doubling, so the true peak
is a bit lower.)

Speed: prog420 2048 58.7 -> 63.1 ms (+7%), 4000x3000 168 -> 179 ms. The
expected locality gain did not appear. The cost is input handling on
this branch: copying the scan data (~2.2 ms for 705 KB, measured) and
reading it back through a per-cursor closure. With experiment 2's
buffered source the copy can be skipped for in-memory sources and the
cursors can read their buffer directly; re-measure when combining.

Tooling note: sb-sprof attributes most samples to `ycc-to-bgr-neon` on
these branches (93% for a baseline image where color conversion is a
few ms), presumably for lack of debug info at (debug 0); timing phases
directly is reliable, the flat profile currently is not.

### 2026-11-01 — Experiment 5: combined, row callback, scaling — done (`exp/5-combined`)

Scope decided with the project owner: combine 1-4, add a row callback and
scaled decoding; threads not wanted.

**Combination** (merge commits up to d3ffbfc). Experiments 2 and 3 merged
into `exp/4-progressive-bands`. Experiment 4's scan cursors now read from
experiment 2's input buffer: with the whole file in memory they point
into the source cache (no copy, `skip-entropy-data` scans past each
scan); otherwise the data is collected into one buffer. All checks pass,
plus: stream and in-memory decodes byte-identical (354 images), three
concatenated JPEGs from one stream.

**Row callback** (4762691). `:row-callback fn` on `decode-stream` /
`decode-image`: called with (buffer start y) per row, top to bottom;
rows are produced per band in a band-sized buffer (YCCK conversion per
band too) and NIL is returned instead of an image. Also: the output
buffer is now only allocated when a frame is decoded, so
`jpeg-file-dimensions` no longer allocates a whole image.
`callback-check.lisp`: rows identical to normal decoding (354 images,
full size and 1/4).

**Scaling** (cccbe92). `:scale` 1, 1/2, 1/4, 1/8. Reduced inverse DCTs of
the lowest NxN coefficients (direct DCT scaling, Vollbeding / libjpeg 7+),
generated unrolled by `define-reduced-idct` from one table function; 1x1
is the DC value. Per-component block sizes as in libjpeg-turbo:
subsampled components are scaled less when both sampling ratios allow
(4:2:0 chroma), otherwise replicated (4:2:2). Progressive scans whose
spectral range starts beyond the coefficients needed are skipped (only
DC scans at 1/8). Output size rounded up as in libjpeg.

Verification: reduced IDCTs match a floating-point evaluation of the same
transform within 1 (100000 random blocks each). Against `djpeg -scale`:
max diff 12-18, mean <= 6 (avg ~2) at 1/2 and 1/4 — libjpeg-turbo uses its
older averaging IDCTs (`jidctred`) for these scales, a different filter;
at 1/8 every non-4:2:0 pixel differs by exactly 1 (see finding below).

| 2048x2048 | stb | combined | + row callback |
|---|---|---|---|
| base420 | 25.2 ms / 18.9 MB | 20.6 ms / 12.7 MB | 0.26 MB |
| base444 | 66.3 ms / 25.2 MB | 59.6 ms / 12.8 MB | 0.24 MB |
| gray | 15.1 ms / 8.4 MB | 13.2 ms / 4.3 MB | |
| prog420 | 49.6 ms / 31.5 MB | 44.4 ms / 12.9 MB | 0.40 MB |
| smooth420 | 16.5 ms / 18.9 MB | 9.2 ms / 12.7 MB | |
| prog420 4000x3000 | 142.0 ms / 90.2 MB | 126.8 ms / 36.5 MB | 0.70 MB |

Scaled (time / allocation, from memory):

| image | 1 | 1/2 | 1/4 | 1/8 |
|---|---|---|---|---|
| base420 2048 | 19.4 ms / 12.7 MB | 18.1 / 3.3 | 15.0 / 0.9 | 12.5 / 0.3 |
| base444 2048 | 58.8 / 12.8 | 63.1 / 3.3 | 49.2 / 0.9 | 48.1 / 0.3 |
| prog420 2048 | 43.6 / 12.9 | 43.4 / 3.4 | 28.6 / 1.0 | 13.4 / 0.4 |
| smooth420 2048 | 9.7 / 12.8 | 9.4 / 3.3 | 6.4 / 0.9 | 3.8 / 0.3 |
| prog420 4000x3000 | 122.5 / 36.5 | 122.5 / 9.4 | 84.6 / 2.6 | 37.9 / 0.9 |

Sequential images stay bound by entropy decoding (every coefficient must
be decoded), so scaling mostly saves memory there; progressive images
also gain speed from skipped scans.

Findings / follow-ups:
- **Level shift bias (pre-existing):** cl-jpeg level shifts IDCT output
  by 127 instead of 128 (and centers chroma on 127), so its output is 1
  lower than libjpeg's everywhere. Hidden by the djpeg check's tolerance
  of 6; visible as an exact 1.00 mean difference at 1/8. Worth fixing in
  a separate change (scalar/NEON/DC/reduced paths and color conversion).
- Band-by-band progressive still costs ~3 ms vs experiment 2 alone
  (prog420 2048: 44.4 vs 41.9 ms); not investigated.
- 1/2 is slightly slower than full size for noisy 4:4:4 (63 vs 59 ms):
  the scalar 4x4 IDCT vs the NEON 8x8. A NEON 4x4 would fix it.
- At 1/2-1/8, sequential decoding could skip storing coefficients the
  reduced IDCT does not read (it must still decode them).

### 2026-11-01 — Level shift fix — done (`exp/5-combined`, 94d84ab)

The 127/128 finding above is fixed: all decoder paths level shift by 128
and center chroma on 128 (IDCT scalar/NEON/DC-only/reduced, color
conversion, YCCK tables, the exported `inverse-llm-dct` limit table).
`simd-check.lisp` on `exp/5-combined` uses the new centering (the copy
on this branch still matches experiments 1-4).

| vs djpeg, 354 test images | before | after |
|---|---|---|
| mean signed difference | -0.98 | **0.000** |
| mean absolute difference | 0.99 | **0.057** |
| worst pixel | 4 | 3 |
| scaled 1/8, non-4:2:0 | exactly 1 everywhere | **0** |

New finding: cl-jpeg's **encoder** has its own bias. A smooth test image
encoded by cl-jpeg (q 95) decodes 0.59 levels dark on average with both
djpeg and the fixed cl-jpeg decoder (the round trip was -1.57 before the
decoder fix). Not investigated; separate from the decoder work.

