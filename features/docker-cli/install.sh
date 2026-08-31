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
# Try centralized resolver if available
if command -v fh_resolve_version >/dev/null 2>&1; then
  # versions.json uses key 'docker' for CLI
  RESOLVED=$(fh_resolve_version "docker" || true)
  if [ -n "${RESOLVED}" ]; then
    VERSION="${RESOLVED}"
  fi
  # write history
  if command -v fh_write_history >/dev/null 2>&1; then
    fh_write_history "{\"feature\":\"docker-cli\",\"resolved_version\":\"${VERSION}\"}"
  fi
fi
ARCH=$(dpkg --print-architecture)

echo "docker-cli: Installing Docker CLI via Docker's upstream installer (get.docker.com)"

# Prefer upstream installer which handles matching packages for the distro/arch.
if command -v curl >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh || true
else
  echo "docker-cli: curl not available; falling back to apt-based install"
  # Add Docker's official GPG key and repo, then attempt apt install
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc || true
  chmod a+r /etc/apt/keyrings/docker.asc || true
  echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update || true
  if [ "${VERSION}" = "latest" ]; then
    apt-get install -y docker-ce docker-buildx-plugin || apt-get install -y docker-ce-cli || true
  else
    apt-get install -y docker-ce="${VERSION}~*" docker-buildx-plugin || apt-get install -y docker-ce-cli="${VERSION}~*" || true
  fi
fi

# Verify installation if available
if command -v docker >/dev/null 2>&1; then
  docker --version || true
  echo "docker-cli: Installation complete"
else
  echo "docker-cli: Installation attempted but 'docker' not found in PATH"
fi
