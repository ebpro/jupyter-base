#!/usr/bin/env bash
set -euo pipefail

if command -v stow >/dev/null 2>&1; then
  echo "stow already installed: $(stow --version 2>/dev/null || true)"
  exit 0
fi

if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends stow
  echo "stow installed via apt"
else
  if command -v brew >/dev/null 2>&1; then
    brew install stow
    echo "stow installed via brew"
  else
    echo "Error: neither apt-get nor brew available to install stow" >&2
    exit 1
  fi
fi

exit 0
