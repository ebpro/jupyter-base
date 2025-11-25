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

if [ "${DEVCONTAINER_NODE_INSTALL_VOLTA:-false}" = "true" ]; then
  echo "node: installing Volta (user-local)"
  su - ${NB_USER:-jovyan} -c "curl https://get.volta.sh | bash -s -- --skip-setup" || true
  echo "node: Volta installed (may require new shell to take effect)"
else
  echo "node: installing nodejs/npm from apt (may be older version)"
  apt-get update && apt-get install -y --no-install-recommends nodejs npm || true
  rm -rf /var/lib/apt/lists/* || true
fi

echo "node: done"
