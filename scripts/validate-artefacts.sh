#!/usr/bin/env bash
# validate-artefacts.sh — verify integrity of the offloaded artefacts tree.
# Usage: scripts/validate-artefacts.sh [artefacts-dir]
set -euo pipefail

ARTEFACTS_DIR="${1:-artefacts}"
FAIL=0

if [ ! -d "$ARTEFACTS_DIR" ]; then
  echo "OK: no artefacts directory at $ARTEFACTS_DIR (nothing to validate)"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

found_manifest=0
for m in "$ARTEFACTS_DIR"/offload/toolcache-manifest-*.json; do
  [ -e "$m" ] || continue
  found_manifest=1
  if ! jq -e '.tarball | select(type == "string")' "$m" >/dev/null 2>&1; then
    echo "FAIL: manifest missing string .tarball: $m" >&2
    FAIL=1
    continue
  fi
  tarball="$ARTEFACTS_DIR/$(jq -r '.tarball' "$m")"
  shafile="$ARTEFACTS_DIR/$(jq -r '.sha256_file // empty' "$m")"
  if [ -f "$tarball" ]; then
    expected=""
    if [ -n "$shafile" ] && [ -f "$shafile" ]; then
      expected=$(awk '{print $1; exit}' "$shafile")
    elif [ -f "$tarball.sha256" ]; then
      expected=$(awk '{print $1; exit}' "$tarball.sha256")
    fi
    if [ -n "$expected" ]; then
      actual=$(sha256sum "$tarball" | awk '{print $1}')
      if [ "$actual" != "$expected" ]; then
        echo "FAIL: checksum mismatch: $tarball" >&2
        FAIL=1
      fi
    else
      echo "WARN: no checksum file for $tarball; skipping verification"
    fi
  else
    echo "INFO: tarball not stored locally (remote): $tarball"
  fi
done

while IFS= read -r cs; do
  if ! jq -e . "$cs" >/dev/null 2>&1; then
    echo "FAIL: invalid JSON: $cs" >&2
    FAIL=1
  fi
done < <(find "$ARTEFACTS_DIR" -name 'checksums.json' -type f)

if [ "$FAIL" -ne 0 ]; then
  echo "artefacts validation FAILED" >&2
  exit 1
fi
[ "$found_manifest" -eq 1 ] || echo "OK: no offload manifests present; nothing to verify"
echo "artefacts validation passed"
