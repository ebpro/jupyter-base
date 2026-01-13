#!/usr/bin/env bash
# Auto-inserted by scripts/inject_prebaked_helpers.sh
# Source shared feature helpers (prebaked into image) or fall back to repository helper
if [ -n "${FEATURE_HELPERS_DIR:-}" ] && [ -f "${FEATURE_HELPERS_DIR}/helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "${FEATURE_HELPERS_DIR}/helpers.sh"
elif [ -f "../../../scripts/feature_helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "../../../scripts/feature_helpers.sh"
fi
set -euo pipefail

VERSION="${VERSION:-0.7.7}"
ARCH=$(dpkg --print-architecture)

echo "ctop: Installing ctop v${VERSION} container monitoring tool"

# Map architecture names for GitHub releases
case "${ARCH}" in
  amd64) RELEASE_ARCH="amd64" ;;
  arm64) RELEASE_ARCH="arm64" ;;
  *) echo "Unsupported architecture: ${ARCH}"; exit 1 ;;
esac

# Download and install from GitHub releases
DOWNLOAD_URL="https://github.com/bcicen/ctop/releases/download/v${VERSION}/ctop-${VERSION}-linux-${RELEASE_ARCH}"

curl -fsSL "${DOWNLOAD_URL}" -o /usr/local/bin/ctop
chmod +x /usr/local/bin/ctop

# Verify installation
ctop -v

echo "ctop: Installation complete"
