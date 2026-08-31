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

VERSION="${VERSION:-2.12.0}"
ARCH=$(dpkg --print-architecture)

echo "hadolint: Installing hadolint v${VERSION} Dockerfile linter"

# Map architecture names for GitHub releases
case "${ARCH}" in
  amd64) RELEASE_ARCH="x86_64" ;;
  arm64) RELEASE_ARCH="arm64" ;;
  *) echo "Unsupported architecture: ${ARCH}"; exit 1 ;;
esac

# Download and install from GitHub releases
DOWNLOAD_URL="https://github.com/hadolint/hadolint/releases/download/v${VERSION}/hadolint-Linux-${RELEASE_ARCH}"

curl -fsSL "${DOWNLOAD_URL}" -o /usr/local/bin/hadolint
chmod +x /usr/local/bin/hadolint

# Verify installation
hadolint --version

echo "hadolint: Installation complete"
