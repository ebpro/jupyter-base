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

# Create non-root user, group, sudoers and basic home directories.
# Idempotent and safe to run as root during image build.

NB_USER=${NB_USER:-jovyan}
NB_UID=${NB_UID:-1001}
NB_GID=${NB_GID:-1001}
HOME_DIR="/home/${NB_USER}"

echo "user feature: ensuring user ${NB_USER} (uid=${NB_UID}) gid=${NB_GID} exists"

# Create group if it doesn't exist
if ! getent group "${NB_GID}" >/dev/null 2>&1; then
  if ! getent group "${NB_USER}" >/dev/null 2>&1; then
    groupadd -g "${NB_GID}" "${NB_USER}" || true
  else
    echo "group name ${NB_USER} exists but gid ${NB_GID} not present; skipping groupadd"
  fi
fi

# Create user if it doesn't exist
if ! id -u "${NB_USER}" >/dev/null 2>&1; then
  useradd -m -s /bin/zsh -u "${NB_UID}" -g "${NB_GID}" -N "${NB_USER}" || true
fi

# Sudoers entry
echo "${NB_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${NB_USER}
chmod 0440 /etc/sudoers.d/${NB_USER} || true

# Ensure directories and basic permissions
mkdir -p "${HOME_DIR}" "${HOME_DIR}/bin" "${HOME_DIR}/.config" "${HOME_DIR}/work"
chown -R "${NB_UID}:${NB_GID}" "${HOME_DIR}" || true

echo "user feature: done"
