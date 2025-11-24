#!/usr/bin/env bash
set -euo pipefail

echo "[feature: python-base] Installing system Python3 and pip"
if command -v apt-get >/dev/null 2>&1; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3 python3-pip
elif command -v apk >/dev/null 2>&1; then
  apk add --no-cache python3 py3-pip
else
  echo "[feature: python-base] Warning: package manager not recognized. Skipping."
fi
