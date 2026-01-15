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

VERSION="${VERSION:-latest}"

echo "trivy: Installing Trivy vulnerability scanner"

# Add Aqua Security's official GPG key
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://aquasecurity.github.io/trivy-repo/deb/public.key -o /etc/apt/keyrings/trivy.asc
chmod a+r /etc/apt/keyrings/trivy.asc

# Add Trivy repository
echo \
  "deb [signed-by=/etc/apt/keyrings/trivy.asc] https://aquasecurity.github.io/trivy-repo/deb \
  $(. /etc/os-release && echo "$VERSION_CODENAME") main" | \
  tee /etc/apt/sources.list.d/trivy.list > /dev/null

apt-get update

# Install Trivy
if [ "${VERSION}" = "latest" ]; then
  apt-get install -y trivy
else
  apt-get install -y trivy="${VERSION}"
fi

# Verify installation
trivy --version

echo "trivy: Installation complete"
