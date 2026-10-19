#!/usr/bin/env bash
set -euo pipefail

# This script lives in <repo>/scripts/utils/, so the repo root is two levels up.
# The old single "/.." assumed the pre-move location (scripts/) and silently
# resolved FEATURES_DIR to the nonexistent scripts/features, turning every run
# into a no-op that still exited 0.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FEATURES_DIR="$ROOT/features"

if [ ! -d "$FEATURES_DIR" ]; then
  echo "features directory not found: $FEATURES_DIR — refusing to run (this would silently inject nothing)" >&2
  exit 1
fi

# Anchored sentinels for the idempotence guard (see loop below):
#   marker  — the exact header line this script injects
#   payload — a real sourcing of the prebaked helpers library
# Deliberately NOT an unanchored "helpers.sh" substring: that also matched
# download-release-helpers.sh / fh_helpers.sh mentions (e.g. features/tilt)
# and wrongly skipped files that were never injected.
marker_re='^# Auto-inserted by scripts/inject_prebaked_helpers[.]sh$'
payload_re='^[[:space:]]*source[[:space:]]+"?[$][{]FEATURE_HELPERS_DIR[}]/helpers[.]sh'

snippet=$(cat <<'SNIP'
# Source shared feature helpers (prebaked into image) or fall back to repository helper
if [ -n "${FEATURE_HELPERS_DIR:-}" ] && [ -f "${FEATURE_HELPERS_DIR}/helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "${FEATURE_HELPERS_DIR}/helpers.sh"
elif [ -f "../../../scripts/lib/features.sh" ]; then
  # shellcheck disable=SC1091
  source "../../../scripts/lib/features.sh"
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
  # Idempotence guard, keyed on the payload actually present, not on any
  # "helpers.sh"-shaped substring. States:
  #   payload >= 1, marker <= 1 -> already sources the helpers (injected or
  #                                hand-written, e.g. features/gh) -> skip
  #   marker == 0, payload == 0 -> never injected -> inject below
  #   marker >= 2               -> stacked injections (e.g. the historical
  #                                double-inject in features/python-conda) -> fail loud
  #   marker >= 1, payload == 0 -> marker without payload (tampered) -> fail loud
  markers=$(grep -cE "$marker_re" "$inst" || true)
  payloads=$(grep -cE "$payload_re" "$inst" || true)
  if [ "$payloads" -ge 1 ] && [ "$markers" -le 1 ]; then
    echo "- ok $d (already sources prebaked helpers)"
    continue
  fi
  if [ "$markers" -ge 2 ] || { [ "$markers" -ge 1 ] && [ "$payloads" -eq 0 ]; }; then
    echo "contradictory helpers-injection state in $inst: $markers marker(s), $payloads prebaked-helpers source(s) — resolve manually" >&2
    exit 1
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
