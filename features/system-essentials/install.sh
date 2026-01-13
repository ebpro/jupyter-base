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

echo "base-apt: installing packages listed in /tmp/inputs/apt-packages_base (if present)"
if [ -f /tmp/inputs/apt-packages_base ]; then
  PKGS=$(grep -v -e "^#" -e "^$" /tmp/inputs/apt-packages_base | tr '\n' ' ' || true)
  PKGS=$(echo "$PKGS" | xargs || true)
  if [ -n "$PKGS" ]; then
    # Use helper apt_install where available for consistent, non-interactive installs
    if command -v apt_install >/dev/null 2>&1; then
      apt_install $PKGS || true
    else
      apt-get update
      apt-get install -y --no-install-recommends $PKGS || true
      rm -rf /var/lib/apt/lists/* || true
    fi
  fi
else
  echo "base-apt: /tmp/inputs/apt-packages_base not present; skipping"
fi

echo "base-apt: done"
