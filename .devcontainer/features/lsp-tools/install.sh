#!/usr/bin/env bash
set -euo pipefail

echo "lsp-tools: installing pyright (if npm available)"
if command -v npm >/dev/null 2>&1; then
  npm install -g pyright || true
else
  echo "lsp-tools: npm not available; skip pyright install"
fi

echo "lsp-tools: done"
