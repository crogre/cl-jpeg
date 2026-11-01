#!/bin/bash
# Peak memory per decode (MB): stb_image vs cl-jpeg, one process per file
cd "$(dirname "$0")"
printf "%-26s %8s %9s\n" image stb cl-jpeg
for f in base420_2048x2048 base444_2048x2048 gray_2048x2048 prog420_2048x2048 base420_4000x3000 prog420_4000x3000; do
  s=$(./stb_mem img/$f.jpg | sed -E 's/.*peak ([0-9.]+) MB.*/\1/')
  c=$(sbcl --dynamic-space-size 8192 --noinform --non-interactive --load alloc.lisp -- img/$f.jpg 2>/dev/null | sed -nE 's/.*consed ([0-9.]+) MB.*/\1/p')
  printf "%-26s %8s %9s\n" $f "$s" "$c"
done
