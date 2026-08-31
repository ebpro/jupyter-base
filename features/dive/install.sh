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

VERSION="${VERSION:-0.12.0}"
ARCH=$(dpkg --print-architecture)

echo "dive: Installing dive v${VERSION} for image layer analysis"

# Map architecture names for GitHub releases
case "${ARCH}" in
  amd64) RELEASE_ARCH="amd64" ;;
  arm64) RELEASE_ARCH="arm64" ;;
  *) echo "Unsupported architecture: ${ARCH}"; exit 1 ;;
esac

# Download and install from GitHub releases
DOWNLOAD_URL="https://github.com/wagoodman/dive/releases/download/v${VERSION}/dive_${VERSION}_linux_${RELEASE_ARCH}.tar.gz"

curl -fsSL "${DOWNLOAD_URL}" -o /tmp/dive.tar.gz
tar -xzf /tmp/dive.tar.gz -C /tmp
mv /tmp/dive /usr/local/bin/dive
chmod +x /usr/local/bin/dive
rm -f /tmp/dive.tar.gz

# Verify installation
dive --version

echo "dive: Installation complete"
