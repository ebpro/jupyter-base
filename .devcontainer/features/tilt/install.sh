#!/usr/bin/env bash
set -euo pipefail

echo "tilt: installing Tilt CLI (best-effort)."

# Resolve version from Artefacts optionally
resolve_version(){
  local tool="$1" v=""
  if [ -f "${PWD}/Artefacts/features/${tool}/versions.json" ]; then
    v=$(jq -r --arg t "$tool" '.tools[$t] // empty' "${PWD}/Artefacts/features/${tool}/versions.json" 2>/dev/null || true)
    [ -n "$v" ] && { echo "$v"; return 0; }
  fi
  if [ -f "${PWD}/Artefacts/versions.json" ]; then
    v=$(jq -r --arg t "$tool" '.tools[$t] // empty' "${PWD}/Artefacts/versions.json" 2>/dev/null || true)
    [ -n "$v" ] && { echo "$v"; return 0; }
  fi
  if [ -f /tmp/versions.json ]; then
    v=$(jq -r --arg t "$tool" '.tools[$t] // empty' /tmp/versions.json 2>/dev/null || true)
    [ -n "$v" ] && { echo "$v"; return 0; }
  fi
  echo ""
}

TILT_VER=$(resolve_version "tilt")
if [ -z "$TILT_VER" ]; then
  echo "tilt: no pinned version found in Artefacts; using system/host installation if available"
fi

# If toolcache exists, prefer it
if command -v toolcache-get >/dev/null 2>&1 && [ -n "$TILT_VER" ]; then
  echo "tilt: attempting to use toolcache-get"
  PREFIX=$(toolcache-get "tilt" "$TILT_VER" "" "" || true)
  if [ -n "$PREFIX" ] && [ -x "$PREFIX/tilt" ]; then
    mkdir -p /usr/local/bin
    cp -a "$PREFIX/tilt" /usr/local/bin/tilt || true
    chmod +x /usr/local/bin/tilt || true
    echo "tilt: installed from toolcache to /usr/local/bin/tilt"
    exit 0
  fi
fi

echo "tilt: no automatic installer available in this environment; attempting best-effort curl install"
if command -v curl >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64|X86_64) DLARCH="x86_64" ;; 
    aarch64|arm64) DLARCH="arm64" ;;
    *) DLARCH="x86_64" ;;
  esac
  if [ -n "$TILT_VER" ]; then
    URL="https://github.com/tilt-dev/tilt/releases/download/v${TILT_VER}/tilt.${TILT_VER}.linux.${DLARCH}.tar.gz"
  else
    URL="https://github.com/tilt-dev/tilt/releases/latest/download/tilt.latest.linux.${DLARCH}.tar.gz"
  fi
  echo "tilt: attempting download from $URL"
  if curl -fsSL "$URL" -o /tmp/tilt.tar.gz; then
    mkdir -p /tmp/tilt-extract
    tar -xzf /tmp/tilt.tar.gz -C /tmp/tilt-extract || true
    if [ -x /tmp/tilt-extract/tilt ]; then
      mv /tmp/tilt-extract/tilt /usr/local/bin/tilt || true
      chmod +x /usr/local/bin/tilt || true
      echo "tilt: installed to /usr/local/bin/tilt"
      rm -rf /tmp/tilt-extract /tmp/tilt.tar.gz || true
      exit 0
    fi
  fi
fi

echo "tilt: installation not completed automatically. Please install Tilt on the host or provide a toolcache entry." >&2
exit 0
