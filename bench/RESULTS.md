# Benchmark results

Measured on commit `9b7765a` (branch `decoder-performance`), against
commit `619c4df` as "before".

Setup: Apple M2 Pro, macOS, SBCL 2.6.9 (sb-simd NEON enabled), stb_image
v2.30 from raylib's `src/external`, Apple clang 21 `-O2`. All decoding is
from memory; times are medians in milliseconds (`run.sh`).

"stb" is stb_image as raylib builds it on ARM64 (no `STBI_NEON`, so scalar);
"stb+neon" adds `-DSTBI_NEON`, which is roughly what raylib gets on x86-64,
where SSE2 is enabled automatically.

## Speed

| image | stb | stb+neon | cl-jpeg | vs stb |
|---|---|---|---|---|
| base420_512x512 | 1.80 | 1.48 | 1.42 | 0.79x |
| base420_1024x1024 | 6.37 | 5.05 | 5.47 | 0.86x |
| base420_2048x2048 | 25.26 | 19.99 | 20.62 | 0.82x |
| base420_4000x3000 | 72.13 | 56.55 | 60.20 | 0.83x |
| base444_512x512 | 4.23 | 3.38 | 4.23 | 1.00x |
| base444_1024x1024 | 16.95 | 13.55 | 16.96 | 1.00x |
| base444_2048x2048 | 67.17 | 53.80 | 67.03 | 1.00x |
| base444_4000x3000 | 192.21 | 153.82 | 188.03 | 0.98x |
| gray_512x512 | 0.95 | 0.74 | 0.94 | 0.99x |
| gray_1024x1024 | 3.80 | 2.89 | 3.77 | 0.99x |
| gray_2048x2048 | 15.23 | 11.57 | 14.42 | 0.95x |
| gray_4000x3000 | 43.73 | 33.00 | 40.82 | 0.93x |
| prog420_512x512 | 3.24 | 2.95 | 3.66 | 1.13x |
| prog420_1024x1024 | 12.73 | 11.54 | 14.32 | 1.12x |
| prog420_2048x2048 | 50.21 | 45.46 | 57.58 | 1.15x |
| prog420_4000x3000 | 142.38 | 128.28 | 170.95 | 1.20x |
| prog420rst_512x512 | 3.27 | 2.91 | 3.89 | 1.19x |
| prog420rst_1024x1024 | 12.79 | 11.54 | 14.96 | 1.17x |
| prog420rst_2048x2048 | 50.19 | 44.91 | 58.47 | 1.16x |
| prog420rst_4000x3000 | 142.86 | 127.03 | 166.26 | 1.16x |

Before (`619c4df`), cl-jpeg was 3.3-4.3x slower than stb on baseline
images and 2.7-2.9x slower on progressive ones.

## Memory

Peak bytes per decode, compressed input excluded. stb is measured with a
counting allocator (`stbmem.c`); cl-jpeg as bytes allocated per decode
(`alloc.lisp`), which equals its peak since everything allocated is live
at the end.

| image | stb | cl-jpeg | cl-jpeg before |
|---|---|---|---|
| base420_2048x2048 | 18.9 MB | 19.0 MB | 12.6 MB |
| base444_2048x2048 | 25.2 MB | 25.3 MB | 12.6 MB |
| gray_2048x2048 | 8.4 MB | 8.4 MB | 4.3 MB |
| prog420_2048x2048 | 31.5 MB | 31.6 MB | 63.0 MB |
| prog420_4000x3000 | 90.2 MB | 90.4 MB | 180.4 MB |

Both decoders now hold per-component planes plus the output for baseline
images, and 16-bit coefficients per component for progressive ones.
