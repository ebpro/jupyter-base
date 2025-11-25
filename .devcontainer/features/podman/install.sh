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

echo "podman: installing podman via apt (if available)"

# Try apt install; many base images include apt
if command -v apt-get >/dev/null 2>&1; then
  apt-get update
  apt-get install -y --no-install-recommends podman || true
  rm -rf /var/lib/apt/lists/* || true
  echo "podman: installed via apt (or apt not available)"
else
  echo "podman: apt-get not found; skipping installation. Please install podman on the host or add a custom installer." >&2
fi

echo "podman: done"

exit 0
