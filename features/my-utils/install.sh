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

NB_USER="${NB_USER:-jovyan}"
NB_UID="${NB_UID:-1001}"
NB_GID="${NB_GID:-1001}"

if command -v fh_ensure_user_dirs >/dev/null 2>&1; then
  fh_ensure_user_dirs "${NB_USER}" "${NB_UID}" "${NB_GID}" || true
else
  HOME_DIR=${HOME_DIR:-/home/${NB_USER}}
  mkdir -p "${HOME_DIR}/.local/bin" "${HOME_DIR}/.cache" "${HOME_DIR}/.cache/pip" >/dev/null 2>&1 || true
  chown -R "${NB_UID}:${NB_GID}" "${HOME_DIR}/.local" "${HOME_DIR}/.cache" >/dev/null 2>&1 || true
fi

HOME_DIR=${HOME_DIR:-/home/${NB_USER}}
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bin"
DEST_DIR="${HOME_DIR}/.local/bin"
mkdir -p "${DEST_DIR}"

for script in "${SRC_DIR}"/*; do
  [ -f "${script}" ] || continue
  name="$(basename "${script}")"
  install -m 0755 "${script}" "${DEST_DIR}/${name}"
  chown "${NB_UID}:${NB_GID}" "${DEST_DIR}/${name}" || true
  echo "my-utils: installed ${DEST_DIR}/${name}"
done
