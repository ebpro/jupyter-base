#!/usr/bin/env bash
set -euo pipefail

# Repo-level pre-render script: generate optimized images before rendering
ROOT_DIR=$(cd "$(dirname "$0")" && pwd)
QUI_UTILS="$ROOT_DIR/_quarto-utils"
GEN="$QUI_UTILS/scripts/gen-webp.sh"

if [ ! -x "$GEN" ]; then
  echo "Making generator executable: $GEN"
  chmod +x "$GEN" || true
fi

echo "Running image generator for _quarto-utils/MyMedia/images -> optimized"
"$GEN" "$QUI_UTILS/MyMedia/images" "$QUI_UTILS/MyMedia/images/optimized"

echo "Pre-render step complete."
