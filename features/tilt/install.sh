#!/usr/bin/env bash
set -euo pipefail

echo "===================================================================="
echo "Feature: Tilt CLI"
echo "===================================================================="

# Source download helper
if [ -f "/usr/local/lib/download-release-helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "/usr/local/lib/download-release-helpers.sh"
else
  echo "❌ tilt: download-release helper not found"
  exit 1
fi

# Resolve version from artefacts
resolve_version(){
  local tool="$1" v=""
  if command -v fh_resolve_version >/dev/null 2>&1; then
    v=$(fh_resolve_version "$tool" || true)
    if [ -n "$v" ]; then
      echo "$v"; return 0
    fi
  fi
  if [ -f "${PWD}/artefacts/versions.json" ]; then
    v=$(jq -r --arg t "$tool" '.tools[$t] // empty' "${PWD}/artefacts/versions.json" 2>/dev/null || true)
  elif [ -f /tmp/versions.json ]; then
    v=$(jq -r --arg t "$tool" '.tools[$t] // empty' /tmp/versions.json 2>/dev/null || true)
  fi
  echo "$v"
}

TILT_VER=$(resolve_version "tilt")
if [ -z "$TILT_VER" ]; then
  # Fail closed: tilt is checksum-pinned (checksums.json tools.tilt) and the
  # mirror (scripts/stage-toolcache.sh) serves exactly the version pinned in
  # versions.json. The repo's designed "latest" mechanism is a per-feature
  # check_version.py hook (features/_lib/fh_helpers.sh), and tilt ships none,
  # so a GitHub-API "latest" here could only ever produce a hard failure at
  # the download_direct integrity gate (no digest for an unpinned version) or
  # depend on digest coincidence between upstream latest and the pin.
  echo "❌ tilt: FH_VERSION_UNRESOLVED — pinned version for 'tilt' not found via fh_resolve_version/artefacts; refusing to fall back to upstream 'latest' (checksum-pinned tool)" >&2
  exit 1
fi

echo "📦 Installing Tilt CLI version: ${TILT_VER}"

# Tilt uses x86_64/arm64 naming (not amd64)
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|X86_64) TILT_ARCH="x86_64" ;;
  aarch64|arm64) TILT_ARCH="arm64" ;;
  *) TILT_ARCH="x86_64" ;;
esac

# Build URL manually since Tilt uses non-standard naming.
# TILT_VER is guaranteed pinned here: the fail-closed check above aborts on
# unresolvable versions, so there is no "latest" path (and no upstream chase).
# Strip leading 'v' from version if present to avoid 'vv' in the URL/filename
TILT_TAG=${TILT_VER#v}
TILT_RESOLVED_VER="$TILT_TAG"
URL="https://github.com/tilt-dev/tilt/releases/download/v${TILT_TAG}/tilt.${TILT_TAG}.linux.${TILT_ARCH}.tar.gz"

download_direct "$URL" "tilt" "$TILT_RESOLVED_VER" "/usr/local/bin"
echo "✅ Tilt installed successfully"
echo "===================================================================="
