#!/bin/bash
# usage: run.sh [label]  - benchmarks cl-jpeg against stb_image, saving results/<label>.txt
cd "$(dirname "$0")"; mkdir -p results; label=${1:-current}
FILES=$(for v in base420 base444 gray prog420 prog420rst; do for s in 512x512 1024x1024 2048x2048 4000x3000; do echo img/${v}_$s.jpg; done; done)
[ -f results/stb_scalar.txt ] || ./stb_scalar $FILES > results/stb_scalar.txt
[ -f results/stb_neon.txt ] || ./stb_neon $FILES > results/stb_neon.txt
sbcl --dynamic-space-size 8192 --noinform --non-interactive --load clbench.lisp -- $FILES 2>/dev/null | grep '\.jpg ' > results/$label.txt
python3 - "$label" <<'PY'
import sys
r=lambda n:dict(l.split() for l in open(f"results/{n}.txt"))
s,ne,c=r("stb_scalar"),r("stb_neon"),r(sys.argv[1])
print(f"{'image':26}{'stb':>9}{'stb+neon':>10}{'cl-jpeg':>10}{'ratio':>8}")
for k in s: print(f"{k:26}{float(s[k]):9.2f}{float(ne[k]):10.2f}{float(c.get(k,'nan')):10.2f}{float(c.get(k,'nan'))/float(s[k]):7.2f}x")
PY
