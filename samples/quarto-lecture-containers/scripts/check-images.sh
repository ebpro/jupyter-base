#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="${1:-_quarto-utils/MyMedia/images}"
OUT_DIR="$SRC_DIR/optimized"

missing=0

echo "Checking optimized images in $OUT_DIR for originals in $SRC_DIR"
shopt -s nullglob
for f in "$SRC_DIR"/*.{jpg,jpeg,png}; do
  [ -f "$f" ] || continue
  base=$(basename "$f")
  name="${base%.*}"
  for size in 400 800; do
    target="$OUT_DIR/${name}-${size}.webp"
    if [ ! -f "$target" ]; then
      echo "MISSING: $target"
      missing=$((missing+1))
    fi
  done
done

if [ "$missing" -eq 0 ]; then
  echo "All optimized files present."
  exit 0
else
  echo "$missing optimized files missing."
  exit 2
fi
