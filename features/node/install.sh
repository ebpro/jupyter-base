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

# Node.js Runtime Installation
# Supports direct binary download (recommended), apt, or volta

VERSION="${VERSION:-22.12.0}"
INSTALL_METHOD="${INSTALLMETHOD:-direct}"

echo "===================================================================="
echo "Feature: Node.js Runtime"
echo "===================================================================="
echo "Version: ${VERSION}"
echo "Install Method: ${INSTALL_METHOD}"
echo "===================================================================="

# Ensure per-user local/cache dirs exist
if command -v fh_ensure_user_dirs >/dev/null 2>&1; then
  fh_ensure_user_dirs "${NB_USER:-jovyan}" "${NB_UID:-1001}" "${NB_GID:-1001}" || true
else
  HOME_DIR=${HOME_DIR:-/home/${NB_USER:-jovyan}}
  mkdir -p "${HOME_DIR}/.local/bin" "${HOME_DIR}/.cache" "${HOME_DIR}/.cache/pip" >/dev/null 2>&1 || true
  chown -R ${NB_UID:-1001}:${NB_GID:-1001} "${HOME_DIR}/.local" "${HOME_DIR}/.cache" >/dev/null 2>&1 || true
fi

# Resolve version from centralized versions.json if available
resolve_version() {
  local tool="$1"
  local default="$2"
  
  # Try feature-specific versions.json first
  if [ -f "/tmp/artefacts/node/versions.json" ]; then
    local ver=$(jq -r ".tools[\"${tool}\"] // empty" "/tmp/artefacts/node/versions.json" 2>/dev/null || true)
    if [ -n "$ver" ] && [ "$ver" != "null" ]; then
      echo "$ver"
      return
    fi
  fi
  
  # Try central versions.json
  if [ -f "/tmp/Artefacts/versions.json" ]; then
    local ver=$(jq -r ".tools[\"${tool}\"] // empty" "/tmp/Artefacts/versions.json" 2>/dev/null || true)
    if [ -n "$ver" ] && [ "$ver" != "null" ]; then
      echo "$ver"
      return
    fi
  fi
  
  # Fallback to default
  echo "$default"
}

# Architecture mapping
map_arch() {
  local arch="$(uname -m)"
  case "$arch" in
    x86_64|X86_64|amd64) echo "x64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "$arch" ;;
  esac
}

if [ "${INSTALL_METHOD}" = "volta" ]; then
  echo "📦 Installing Node.js via Volta (user-local)..."
  su - ${NB_USER:-jovyan} -c "curl https://get.volta.sh | bash -s -- --skip-setup" || true
  echo "✅ Volta installed (requires new shell to take effect)"
  
elif [ "${INSTALL_METHOD}" = "apt" ]; then
  echo "📦 Installing Node.js from Ubuntu APT..."
  if command -v apt_install >/dev/null 2>&1; then
    apt_install nodejs npm || true
  else
    apt-get update && apt-get install -y --no-install-recommends nodejs npm || true
  fi
  rm -rf /var/lib/apt/lists/* || true
  echo "✅ Node.js installed from APT"
  
else
  # Direct binary download (recommended)
  echo "📦 Installing Node.js via direct binary download..."
  
  # Resolve version
  if [ "${VERSION}" = "latest" ]; then
    NODE_VERSION=$(resolve_version "node" "22.12.0")
  else
    NODE_VERSION=$(resolve_version "node" "${VERSION}")
  fi
  
  ARCH=$(map_arch)
  echo "Resolved version: ${NODE_VERSION}"
  echo "Architecture: ${ARCH}"
  
  # Download Node.js official binary
  NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${ARCH}.tar.xz"
  echo "Download URL: ${NODE_URL}"
  
  TMPDIR="/tmp/node-install"
  mkdir -p "${TMPDIR}"
  
  echo "Downloading Node.js ${NODE_VERSION}..."
  curl -fsSL "${NODE_URL}" -o "${TMPDIR}/node.tar.xz"
  
  echo "Extracting Node.js..."
  tar -xJf "${TMPDIR}/node.tar.xz" -C "${TMPDIR}"
  
  # Install to /usr/local
  NODE_DIR="${TMPDIR}/node-v${NODE_VERSION}-linux-${ARCH}"
  cp -r "${NODE_DIR}/bin"/* /usr/local/bin/
  cp -r "${NODE_DIR}/lib"/* /usr/local/lib/
  cp -r "${NODE_DIR}/include"/* /usr/local/include/ 2>/dev/null || true
  cp -r "${NODE_DIR}/share"/* /usr/local/share/ 2>/dev/null || true
  
  # Cleanup
  rm -rf "${TMPDIR}"
  
  echo "✅ Node.js ${NODE_VERSION} installed successfully"
fi

# Verify installation
echo ""
echo "🔍 Verifying Node.js installation..."
if command -v node >/dev/null 2>&1; then
  node --version
  npm --version
  echo ""
  echo "✅ Node.js runtime installed successfully!"
  echo ""
  echo "Available commands:"
  echo "  - node: JavaScript runtime"
  echo "  - npm: Node package manager"
  echo ""
  echo "Example usage:"
  echo "  node --version"
  echo "  npm install -g typescript"
else
  echo "⚠️  Node.js not found in PATH (may require new shell if using Volta)"
fi

echo "node: done"
