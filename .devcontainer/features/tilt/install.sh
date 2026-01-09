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

# Resolve version from Artefacts
resolve_version(){
  local tool="$1" v=""
  if [ -f "${PWD}/Artefacts/versions.json" ]; then
    v=$(jq -r --arg t "$tool" '.tools[$t] // empty' "${PWD}/Artefacts/versions.json" 2>/dev/null || true)
  elif [ -f /tmp/versions.json ]; then
    v=$(jq -r --arg t "$tool" '.tools[$t] // empty' /tmp/versions.json 2>/dev/null || true)
  fi
  echo "$v"
}

TILT_VER=$(resolve_version "tilt")
if [ -z "$TILT_VER" ]; then
  echo "⚠️  tilt: Version not found in Artefacts, using latest"
  TILT_VER="latest"
fi

echo "📦 Installing Tilt CLI version: ${TILT_VER}"

# Tilt uses x86_64/arm64 naming (not amd64)
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|X86_64) TILT_ARCH="x86_64" ;;
  aarch64|arm64) TILT_ARCH="arm64" ;;
  *) TILT_ARCH="x86_64" ;;
esac

# Build URL manually since Tilt uses non-standard naming
if [ "$TILT_VER" = "latest" ]; then
  # For latest, use the GitHub API to get the actual version tag first
  LATEST_TAG=$(curl -sL https://api.github.com/repos/tilt-dev/tilt/releases/latest | jq -r '.tag_name // "v0.33.20"' | sed 's/^v//')
  URL="https://github.com/tilt-dev/tilt/releases/download/v${LATEST_TAG}/tilt.${LATEST_TAG}.linux.${TILT_ARCH}.tar.gz"
else
  URL="https://github.com/tilt-dev/tilt/releases/download/v${TILT_VER}/tilt.${TILT_VER}.linux.${TILT_ARCH}.tar.gz"
fi

download_direct "$URL" "tilt" "/usr/local/bin"
echo "✅ Tilt installed successfully"
echo "===================================================================="
