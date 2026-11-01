#!/bin/bash
# Fetches stb_image.h (as vendored by raylib), builds the stb benchmark and
# generates the benchmark and correctness test images. Needs ImageMagick and
# libjpeg's cjpeg/djpeg.
set -e
cd "$(dirname "$0")"
[ -f stb_image.h ] || curl -sSfLo stb_image.h https://raw.githubusercontent.com/raysan5/raylib/master/src/external/stb_image.h
cc -O2 -o stb_scalar stbbench.c          # raylib's configuration on ARM (no STBI_NEON)
cc -O2 -DSTBI_NEON -o stb_neon stbbench.c 2>/dev/null || cp stb_scalar stb_neon

# Benchmark images: noisy, photo-like content, 4 sizes x 5 variants
mkdir -p img
for sz in 512x512 1024x1024 2048x2048 4000x3000; do
  [ -f img/prog420rst_$sz.jpg ] && continue
  magick -size $sz plasma:fractal -seed 7 \( -size $sz gradient:white-navy \) -compose multiply -composite -attenuate 0.4 +noise Gaussian img/src.ppm
  magick img/src.ppm -colorspace gray img/src.pgm
  cjpeg -quality 85 -sample 2x2 img/src.ppm > img/base420_$sz.jpg
  cjpeg -quality 95 -sample 1x1 img/src.ppm > img/base444_$sz.jpg
  cjpeg -quality 85 img/src.pgm > img/gray_$sz.jpg
  cjpeg -quality 85 -sample 2x2 -progressive img/src.ppm > img/prog420_$sz.jpg
  cjpeg -quality 85 -sample 2x2 -progressive -restart 1 img/src.ppm > img/prog420rst_$sz.jpg
done
# Smooth content (many blocks with few or no AC coefficients)
for sz in 512x512 1024x1024 2048x2048 4000x3000; do
  [ -f img/smooth420_$sz.jpg ] && continue
  magick -size $sz plasma:fractal -seed 11 -blur 0x4 \( -size $sz gradient:white-navy \) -compose multiply -composite img/src.ppm
  cjpeg -quality 85 -sample 2x2 img/src.ppm > img/smooth420_$sz.jpg
done
rm -f img/src.ppm img/src.pgm

# Correctness images with djpeg reference output: odd sizes, all sampling
# factors, restart intervals, progressive/sequential/non-interleaved
if [ ! -f check/list.txt ]; then
  mkdir -p check; cd check; : > list.txt
  add() { cjpeg "${@:2}" > $1.jpg && djpeg -dct float -nosmooth $1.jpg > $1.ref && echo $1 >> list.txt; }
  for sz in 161x97 173x97 8x8 1x1 33x17 250x131; do
    magick -size $sz plasma:fractal -seed 3 s$sz.ppm
    magick s$sz.ppm -colorspace gray g$sz.pgm
    for samp in 1x1 2x1 2x2 1x2 4x1; do for rst in none 1 2B 3B 7B; do
      r=(); [ $rst != none ] && r=(-restart $rst)
      add prog_${sz}_${samp}_$rst -sample $samp -progressive "${r[@]}" s$sz.ppm
      add base_${sz}_${samp}_$rst -sample $samp "${r[@]}" s$sz.ppm
    done; done
    for rst in none 1 5B; do r=(); [ $rst != none ] && r=(-restart $rst)
      add prog_${sz}_gray_$rst -progressive "${r[@]}" g$sz.pgm
      add base_${sz}_gray_$rst "${r[@]}" g$sz.pgm; done
    add prog_${sz}_opt -progressive -optimize -restart 3B s$sz.ppm
    # sequential, one scan per component (non-interleaved)
    printf '0;\n1;\n2;\n' > seq.scans
    add seqscans_${sz}_2x2 -sample 2x2 -scans seq.scans s$sz.ppm
    add seqscans_${sz}_2x1_rst -sample 2x1 -restart 2B -scans seq.scans s$sz.ppm
    rm -f s$sz.ppm g$sz.pgm
  done
fi

# djpeg references for scaled decoding (scale-check.lisp)
if [ ! -f check/scaled/.done ]; then
  mkdir -p check/scaled
  for d in 2 4 8; do
    for f in $(cat check/list.txt); do
      djpeg -dct int -nosmooth -scale 1/$d check/$f.jpg > check/scaled/${f}_$d.ref
    done
  done
  touch check/scaled/.done
fi
