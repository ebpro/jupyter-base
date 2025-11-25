#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FEATURES_DIR="$ROOT/.devcontainer/features"

snippet=$(cat <<'SNIP'
# Source shared feature helpers (prebaked into image) or fall back to repository helper
if [ -n "${FEATURE_HELPERS_DIR:-}" ] && [ -f "${FEATURE_HELPERS_DIR}/helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "${FEATURE_HELPERS_DIR}/helpers.sh"
elif [ -f "../../../scripts/feature_helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "../../../scripts/feature_helpers.sh"
fi
SNIP
)

echo "Scanning features in $FEATURES_DIR"
count=0
for d in "$FEATURES_DIR"/*; do
  [ -d "$d" ] || continue
  inst="$d/install.sh"
  if [ ! -f "$inst" ]; then
    echo "- skip $d (no install.sh)"
    continue
  fi
  # check if file already sources helpers
  if grep -qE "FEATURE_HELPERS_DIR|feature_helpers.sh|helpers.sh" "$inst"; then
    echo "- ok $d (already sources helpers)"
    continue
  fi
  echo "- injecting helpers sourcing into $inst"
  # create a temp file with snippet + original content
  tmp=$(mktemp)
  printf "%s\n" "# Auto-inserted by scripts/inject_prebaked_helpers.sh" > "$tmp"
  printf "%s\n" "$snippet" >> "$tmp"
  cat "$inst" >> "$tmp"
  mv "$tmp" "$inst"
  chmod +x "$inst"
  count=$((count+1))
done

echo "Injected helpers into $count feature install.sh files"
