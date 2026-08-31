# Auto-inserted by scripts/inject_prebaked_helpers.sh
# Source shared feature helpers (prebaked into image) or fall back to repository helper
if [ -n "${FEATURE_HELPERS_DIR:-}" ] && [ -f "${FEATURE_HELPERS_DIR}/helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "${FEATURE_HELPERS_DIR}/helpers.sh"
elif [ -f "../../../scripts/feature_helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "../../../scripts/feature_helpers.sh"
fi
#!/usr/bin/env bash
set -euo pipefail

# TypeScript Compiler Installation
# Installs TypeScript and Node type definitions globally via npm

VERSION="${VERSION:-latest}"

echo "===================================================================="
echo "Feature: TypeScript"
echo "===================================================================="
echo "TypeScript Version: ${VERSION}"
echo "===================================================================="

# Verify Node.js is available
if ! command -v node >/dev/null 2>&1; then
  echo "❌ Node.js not found. Please install the 'node' feature first."
  exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "❌ npm not found. Please install the 'node' feature first."
  exit 1
fi

echo "Node.js: $(node --version)"
echo "npm: $(npm --version)"

# Resolve version from centralized versions.json if available
resolve_version() {
  local tool="$1"
  local default="$2"
  if command -v fh_resolve_version >/dev/null 2>&1; then
    local v
    v=$(fh_resolve_version "$tool" || true)
    if [ -n "$v" ]; then
      printf '%s' "$v"
      return 0
    fi
  fi
  # fallback to previous behavior
  if [ -f "/tmp/artefacts/${tool}/versions.json" ]; then
    local ver=$(jq -r ".tools[\"${tool}\"] // empty" "/tmp/artefacts/${tool}/versions.json" 2>/dev/null || true)
    if [ -n "$ver" ] && [ "$ver" != "null" ]; then
      echo "$ver"
      return
    fi
  fi
  if [ -f "/tmp/artefacts/versions.json" ]; then
    local ver=$(jq -r ".tools[\"${tool}\"] // empty" "/tmp/artefacts/versions.json" 2>/dev/null || true)
    if [ -n "$ver" ] && [ "$ver" != "null" ]; then
      echo "$ver"
      return
    fi
  fi
  echo "$default"
}

echo "📦 Installing TypeScript globally..."

# Determine TypeScript version
if [ "${VERSION}" = "latest" ]; then
  TS_VERSION=$(resolve_version "typescript" "latest")
  if [ "${TS_VERSION}" = "latest" ]; then
    npm install -g typescript @types/node
  else
    npm install -g typescript@${TS_VERSION} @types/node
  fi
else
  TS_VERSION=$(resolve_version "typescript" "${VERSION}")
  npm install -g typescript@${TS_VERSION} @types/node
fi

# write history
if command -v fh_write_history >/dev/null 2>&1; then
  fh_write_history "{\"feature\":\"typescript\",\"resolved_version\":\"${TS_VERSION}\"}"
fi

# Verify installation
echo ""
echo "🔍 Verifying TypeScript installation..."
tsc --version

echo ""
echo "✅ TypeScript installed successfully!"
echo ""
echo "Available commands:"
echo "  - tsc: TypeScript compiler"
echo "  - tsserver: TypeScript language server"
echo ""
echo "Example usage:"
echo "  tsc --init             # Create tsconfig.json"
echo "  tsc file.ts            # Compile TypeScript file"
echo "  tsc --watch            # Watch mode"
echo ""
echo "TypeScript version: $(tsc --version)"
