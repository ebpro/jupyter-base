#!/usr/bin/env bash
# Auto-inserted by scripts/inject_prebaked_helpers.sh
# Source shared feature helpers (prebaked into image) or fall back to repository helper
if [ -n "${FEATURE_HELPERS_DIR:-}" ] && [ -f "${FEATURE_HELPERS_DIR}/helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "${FEATURE_HELPERS_DIR}/helpers.sh"
elif [ -f "../../../scripts/lib/features.sh" ]; then
  # shellcheck disable=SC1091
  source "../../../scripts/lib/features.sh"
fi
set -euo pipefail

# Resolve the version from the SoT (versions/versions.yaml -> versions.json),
# fail closed. dive is checksum-pinned (checksums.json tools.dive) and mirrored
# by scripts/stage-toolcache.sh; it must never fall back to upstream "latest"
# or to a bare curl (tilt/gh precedent).
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

VERSION=$(resolve_version "dive")
if [ -z "$VERSION" ]; then
  echo "❌ dive: FH_VERSION_UNRESOLVED — pinned version for 'dive' not found via fh_resolve_version/artefacts; refusing to fall back to upstream 'latest' (checksum-pinned tool)" >&2
  exit 1
fi

if ! command -v download_direct >/dev/null 2>&1; then
  echo "❌ dive: download_direct helper not found (features/_lib/download-release must run first)" >&2
  exit 1
fi

ARCH=$(dpkg --print-architecture)

echo "dive: Installing dive v${VERSION} for image layer analysis"

# Map architecture names for GitHub releases
case "${ARCH}" in
  amd64) RELEASE_ARCH="amd64" ;;
  arm64) RELEASE_ARCH="arm64" ;;
  *) echo "Unsupported architecture: ${ARCH}"; exit 1 ;;
esac

# Route through the digest-pinned toolcache. tar.gz with the 'dive' binary at
# the archive root -> extract=true; download_direct's extraction path finds
# the $tool binary and installs to /usr/local/bin/dive (equivalent to the
# previous manual tar/mv/chmod, with digest verification added).
DOWNLOAD_URL="https://github.com/wagoodman/dive/releases/download/v${VERSION}/dive_${VERSION}_linux_${RELEASE_ARCH}.tar.gz"
download_direct "$DOWNLOAD_URL" "dive" "$VERSION" "/usr/local/bin" true

# Verify installation
dive --version

echo "dive: Installation complete"
