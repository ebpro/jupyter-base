#!/usr/bin/env bash
set -euo pipefail

# Validate artefact checksums against Artefacts/checksums.json
# Usage: scripts/validate-artefacts.sh [ARTIFACTS_DIR]

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
ARTIFACTS_DIR="${1:-$REPO_ROOT/Artefacts}"
CHECKSUMS_FILE="$ARTIFACTS_DIR/checksums.json"

if [[ ! -f "$CHECKSUMS_FILE" ]]; then
  echo "No checksums.json found at $CHECKSUMS_FILE"
  exit 0
fi

echo "Validating artefact checksums..."

PASS=0
FAIL=0

mapfile -t tools < <(jq -r 'keys[]' "$CHECKSUMS_FILE")

for tool in "${tools[@]}"; do
  [[ -z "$tool" ]] && continue
  mapfile -t versions < <(jq -r --arg t "$tool" '.[$t] | keys[]' "$CHECKSUMS_FILE")

  for version in "${versions[@]}"; do
    [[ -z "$version" ]] && continue
    mapfile -t archs < <(jq -r --arg t "$tool" --arg v "$version" '.[$t][$v] | keys[]' "$CHECKSUMS_FILE")

    for arch in "${archs[@]}"; do
      [[ -z "$arch" ]] && continue
      sha=$(jq -r --arg t "$tool" --arg v "$version" --arg a "$arch" '.[$t][$v][$a]' "$CHECKSUMS_FILE")
      [[ -z "$sha" ]] && continue

      base="$ARTIFACTS/features/$tool/toolcache/$tool/$version/$arch"
      file=""
      if [[ -f "$base/$tool" ]]; then
        file="$base/$tool"
      elif [[ -f "$base/$tool.tar.gz" ]]; then
        file="$base/$tool.tar.gz"
      elif [[ -f "$base/$tool.tgz" ]]; then
        file="$base/$tool.tgz"
      fi

      if [[ -z "$file" ]]; then
        echo "  SKIP: $tool $version $arch (binary not present)"
        continue
      fi

      if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$file" | awk '{print $1}')
      elif command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "$file" | awk '{print $1}')
      else
        echo "  WARN: no checksum tool available"
        continue
      fi

      if [[ "$actual" == "$sha" ]]; then
        echo "  OK: $tool $version $arch"
        ((PASS++)) || true
      else
        echo "  FAIL: $tool $version $arch expected=$sha got=$actual"
        ((FAIL++)) || true
      fi
    done
  done
done

echo ""
echo "Artefact validation: $PASS OK, $FAIL FAIL"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
