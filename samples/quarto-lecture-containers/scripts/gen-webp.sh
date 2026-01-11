#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="${1:-_quarto-utils/MyMedia/images}"
OUT_DIR="${2:-$SRC_DIR/optimized}"

mkdir -p "$OUT_DIR"
shopt -s nullglob
for f in "$SRC_DIR"/*.{jpg,jpeg,png}; do
  [ -f "$f" ] || continue
  name=$(basename "$f")
  base="${name%.*}"
  if [ ! -f "$OUT_DIR/${base}-800.webp" ]; then
    magick "$f" -strip -resize 800x -quality 80 "$OUT_DIR/${base}-800.webp"
    echo "Created $OUT_DIR/${base}-800.webp"
  fi
  if [ ! -f "$OUT_DIR/${base}-400.webp" ]; then
    magick "$f" -strip -resize 400x -quality 80 "$OUT_DIR/${base}-400.webp"
    echo "Created $OUT_DIR/${base}-400.webp"
  fi
done
