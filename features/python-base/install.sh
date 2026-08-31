#!/usr/bin/env bash
set -euo pipefail

# Ensure per-user local/cache dirs exist (use helper when available, fallback otherwise)
if command -v fh_ensure_user_dirs >/dev/null 2>&1; then
  fh_ensure_user_dirs "${NB_USER:-jovyan}" "${NB_UID:-1001}" "${NB_GID:-1001}" || true
else
  HOME_DIR=${HOME_DIR:-/home/${NB_USER:-jovyan}}
  mkdir -p "${HOME_DIR}/.local/bin" "${HOME_DIR}/.cache" "${HOME_DIR}/.cache/pip" >/dev/null 2>&1 || true
  chown -R ${NB_UID:-1001}:${NB_GID:-1001} "${HOME_DIR}/.local" "${HOME_DIR}/.cache" >/dev/null 2>&1 || true
fi

# Feature metadata (must match feature.json)
FEATURE_ID="python-base"
FEATURE_VERSION="1.0.0"

# Source helpers (relative path from .devcontainer/features/<name>/install.sh)
if [ -f "../../../scripts/lib/features.sh" ]; then
  # shellcheck disable=SC1091
  source "../../../scripts/lib/features.sh"
fi

if feature_is_installed; then
  fh_log "already installed; skipping"
  exit 0
fi

fh_log "Installing system Python3 and pip"
if command -v apt-get >/dev/null 2>&1; then
  apt_install python3 python3-pip
elif command -v apk >/dev/null 2>&1; then
  fh_log "using apk to install python3"
  apk add --no-cache python3 py3-pip
else
  fh_log "Warning: package manager not recognized. Skipping."
fi

feature_mark_installed

