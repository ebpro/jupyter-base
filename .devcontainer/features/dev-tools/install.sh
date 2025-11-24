#!/usr/bin/env bash
set -euo pipefail

# This feature installs build tools and monitoring utilities.
PKGS="build-essential cmake pkg-config python3-dev libssl-dev libffi-dev git htop lsof strace"

echo "dev-tools: installing packages: ${PKGS}"
apt-get update && apt-get install -y --no-install-recommends ${PKGS} || true
rm -rf /var/lib/apt/lists/* || true

echo "dev-tools: done"
