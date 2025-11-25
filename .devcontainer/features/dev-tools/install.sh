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

# This feature installs build tools and monitoring utilities.
PKGS="build-essential cmake pkg-config python3-dev libssl-dev libffi-dev git htop lsof strace"

echo "dev-tools: installing packages: ${PKGS}"
apt-get update && apt-get install -y --no-install-recommends ${PKGS} || true
rm -rf /var/lib/apt/lists/* || true

echo "dev-tools: done"
