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

NB_USER=${NB_USER:-jovyan}
NB_UID=${NB_UID:-1001}
NB_GID=${NB_GID:-1001}
HOME_DIR="/home/${NB_USER}"

if [ ! -f /tmp/codeserver_extensions ]; then
  echo "codeserver-extensions: /tmp/codeserver_extensions not present; skipping"
  exit 0
fi

echo "codeserver-extensions: reading extensions from /tmp/codeserver_extensions"
while IFS= read -r ext; do
  ext=$(echo "$ext" | sed -e 's/^#.*$//' -e 's/^\s*//' -e 's/\s*$//')
  if [ -z "$ext" ]; then
    continue
  fi
  echo "codeserver-extensions: would install extension $ext (requires code-server CLI at runtime)"
done < /tmp/codeserver_extensions

echo "codeserver-extensions: finished (note: actual install requires code-server runtime to be present)"
