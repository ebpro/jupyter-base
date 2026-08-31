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

echo "docker-compose: Installing Docker Compose plugin"

# Install from Docker repository (should be available since docker-cli is a dependency)
apt-get update
apt-get install -y docker-compose-plugin

# Verify installation
if ! docker compose version >/dev/null 2>&1; then
  echo "docker-compose: 'docker compose' not recognized, attempting to register plugin"
  # Common locations for the compose plugin binary installed by the package
  candidates=(
    /usr/libexec/docker/cli-plugins/docker-compose
    /usr/lib/docker/cli-plugins/docker-compose
    /usr/local/lib/docker/cli-plugins/docker-compose
    /usr/bin/docker-compose
    /usr/local/bin/docker-compose
  )
  for c in "${candidates[@]}"; do
    if [ -x "$c" ]; then
      mkdir -p /usr/local/lib/docker/cli-plugins
      ln -sf "$c" /usr/local/lib/docker/cli-plugins/docker-compose
      chmod +x /usr/local/lib/docker/cli-plugins/docker-compose || true
      break
    fi
  done
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "docker-compose: WARNING: 'docker compose' still not available after registering plugin"
  echo "docker-compose: You may need to install the compose plugin or use the standalone binary"
else
  echo "docker-compose: Installation complete"
fi
