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

echo "docker-buildx: Installing Docker Buildx plugin"

# Install from Docker repository (should be available since docker-cli is a dependency)
apt-get update
apt-get install -y docker-buildx-plugin

# Verify installation (tolerant): try the CLI plugin, else register candidate binaries
if ! docker buildx version >/dev/null 2>&1; then
  echo "docker-buildx: 'docker buildx' not recognized, attempting to register plugin"
  candidates=(
    /usr/libexec/docker/cli-plugins/docker-buildx
    /usr/lib/docker/cli-plugins/docker-buildx
    /usr/local/lib/docker/cli-plugins/docker-buildx
    /usr/bin/buildx
    /usr/local/bin/buildx
  )
  for c in "${candidates[@]}"; do
    if [ -x "$c" ]; then
      mkdir -p /usr/local/lib/docker/cli-plugins
      ln -sf "$c" /usr/local/lib/docker/cli-plugins/docker-buildx
      chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx || true
      break
    fi
  done
fi

if ! docker buildx version >/dev/null 2>&1; then
  echo "docker-buildx: WARNING: 'docker buildx' still not available after registering plugin"
else
  echo "docker-buildx: Installation complete"
fi
