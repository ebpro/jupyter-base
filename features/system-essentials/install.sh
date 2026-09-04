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

# Ensure per-user local/cache dirs exist (use helper when available, fallback otherwise)
if command -v fh_ensure_user_dirs >/dev/null 2>&1; then
  fh_ensure_user_dirs "${NB_USER:-jovyan}" "${NB_UID:-1001}" "${NB_GID:-1001}" || true
else
  HOME_DIR=${HOME_DIR:-/home/${NB_USER:-jovyan}}
  mkdir -p "${HOME_DIR}/.local/bin" "${HOME_DIR}/.cache" "${HOME_DIR}/.cache/pip" >/dev/null 2>&1 || true
  chown -R ${NB_UID:-1001}:${NB_GID:-1001} "${HOME_DIR}/.local" "${HOME_DIR}/.cache" >/dev/null 2>&1 || true
fi

APT_LIST="/tmp/inputs/apt-packages/base"
if [ ! -f "${APT_LIST}" ] && [ -f /tmp/inputs/apt-packages_base ]; then
  APT_LIST="/tmp/inputs/apt-packages_base"
fi

echo "system-essentials: installing packages listed in ${APT_LIST} (if present)"
if [ -f "${APT_LIST}" ]; then
  PKGS=$(grep -v -e "^#" -e "^$" "${APT_LIST}" | tr '\n' ' ' || true)
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
  echo "system-essentials: ${APT_LIST} not present; skipping"
fi

echo "system-essentials: done"
