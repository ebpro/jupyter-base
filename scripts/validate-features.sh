#!/usr/bin/env bash
set -euo pipefail

# validate-features.sh
# Validate .devcontainer/features for expected files and basic schema consistency.

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
FAILED=0

echo "Validating features under .devcontainer/features"

for d in "$ROOT"/.devcontainer/features/*; do
  [ -d "$d" ] || continue
  name=$(basename "$d")
  fjson="$d/feature.json"
  finst="$d/install.sh"
  echo -n "- $name: "
  missing=()
  if [ ! -f "$fjson" ]; then
    missing+=(feature.json)
  else
    if ! jq -e . "$fjson" >/dev/null 2>&1; then
      echo "INVALID JSON in $fjson" >&2
      FAILED=1
      continue
    fi
    # check required keys
    for key in id name version; do
      if [ "$(jq -r --arg k "$key" '.[$k] // empty' "$fjson")" = "" ]; then
        echo "(missing $key)" >&2
        missing+=("$key")
      fi
    done
  fi
  if [ ! -f "$finst" ]; then
    missing+=(install.sh)
  else
    # check first line for shebang
    first=$(sed -n '1p' "$finst" || true)
    if [[ ! "$first" =~ ^#! ]]; then
      missing+=("shebang-top")
    fi
  fi

  if [ ${#missing[@]} -gt 0 ]; then
    echo "ISSUES: ${missing[*]}"
    FAILED=1
  else
    echo "OK"
  fi
done

if [ "$FAILED" -ne 0 ]; then
  echo
  echo "One or more features have issues. Recommended actions:" >&2
  echo " - Ensure each feature has a valid feature.json with keys: id, name, version" >&2
  echo " - Ensure install.sh begins with a shebang on the first line (#!/usr/bin/env bash)" >&2
  echo " - If installer scripts are sourced rather than executed, ensure callers use 'bash <file>' or adjust scripts to be POSIX-compliant." >&2
  exit 2
fi

echo "All features passed basic validation"
exit 0
