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
  
  # Try feature-specific versions.json first
  if [ -f "/tmp/artefacts/typescript/versions.json" ]; then
    local ver=$(jq -r ".tools[\"${tool}\"] // empty" "/tmp/artefacts/typescript/versions.json" 2>/dev/null || true)
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
