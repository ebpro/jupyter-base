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

NB_USER=${NB_USER:-jovyan}
NB_UID=${NB_UID:-1001}
NB_GID=${NB_GID:-1001}
HOME_DIR="/home/${NB_USER}"

echo "git-lfs: installing git-lfs"

if ! command -v git-lfs >/dev/null 2>&1; then
  apt-get update && apt-get install -y --no-install-recommends git-lfs || true
  rm -rf /var/lib/apt/lists/* || true
fi

# Ensure git-lfs is initialized for the user
su - ${NB_USER} -c "git lfs install --skip-repo" || true

echo "git-lfs: done"
