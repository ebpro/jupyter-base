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

echo "buildah: Installing Buildah OCI image builder"

# Temporary workaround: some `buildah` packages crash during installation
# inside QEMU/emulated amd64 build legs (SIGSEGV). Skip installing on
# amd64 to allow multi-arch builds to complete; revisit for a proper fix.
arch="$(uname -m)"
if [ "$arch" = "x86_64" ] || [ "$arch" = "amd64" ]; then
  echo "buildah: skipping install on platform '$arch' (workaround for SIGSEGV in package)"
  exit 0
fi

apt-get update
apt-get install -y buildah

# Verify installation
buildah --version

echo "buildah: Installation complete"
