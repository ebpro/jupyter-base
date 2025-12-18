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

# Ensure per-user local/cache dirs exist (use helper when available, fallback otherwise)
if command -v fh_ensure_user_dirs >/dev/null 2>&1; then
  fh_ensure_user_dirs "${NB_USER:-jovyan}" "${NB_UID:-1001}" "${NB_GID:-1001}" || true
else
  HOME_DIR=${HOME_DIR:-/home/${NB_USER:-jovyan}}
  mkdir -p "${HOME_DIR}/.local/bin" "${HOME_DIR}/.cache" "${HOME_DIR}/.cache/pip" >/dev/null 2>&1 || true
  chown -R ${NB_UID:-1001}:${NB_GID:-1001} "${HOME_DIR}/.local" "${HOME_DIR}/.cache" >/dev/null 2>&1 || true
fi

if [ "${DEVCONTAINER_NODE_INSTALL_VOLTA:-false}" = "true" ]; then
  echo "node: installing Volta (user-local)"
  su - ${NB_USER:-jovyan} -c "curl https://get.volta.sh | bash -s -- --skip-setup" || true
  echo "node: Volta installed (may require new shell to take effect)"
else
  echo "node: installing nodejs/npm from apt (may be older version)"
  if command -v apt_install >/dev/null 2>&1; then
    apt_install nodejs npm || true
  else
    apt-get update && apt-get install -y --no-install-recommends nodejs npm || true
  fi
  rm -rf /var/lib/apt/lists/* || true
fi

echo "node: done"
