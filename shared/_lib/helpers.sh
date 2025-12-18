#!/usr/bin/env bash
# Helper functions for feature install scripts (shared library)
set -euo pipefail

# Directory where features can mark installation state
FEATURE_MARK_DIR=/opt/.features

fh_log() {
  echo "[feature] $*"
}

feature_marker() {
  local id="${FEATURE_ID:-unknown}"
  local ver="${FEATURE_VERSION:-unknown}"
  mkdir -p "$FEATURE_MARK_DIR"
  printf "%s-%s" "$id" "$ver"
}

feature_is_installed() {
  local m
  m=$(feature_marker)
  [ -f "$FEATURE_MARK_DIR/$m" ]
}

feature_mark_installed() {
  local m
  m=$(feature_marker)
  mkdir -p "$FEATURE_MARK_DIR"
  touch "$FEATURE_MARK_DIR/$m"
}

apt_install() {
  # wrapper that installs via apt-get non-interactively
  if [ "$EUID" -ne 0 ]; then
    fh_log "apt_install requires root privileges"
    return 1
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends "$@"
}

apk_install() {
  if [ "$EUID" -ne 0 ]; then
    fh_log "apk_install requires root privileges"
    return 1
  fi
  apk add --no-cache "$@"
}

dnf_install() {
  if [ "$EUID" -ne 0 ]; then
    fh_log "dnf_install requires root privileges"
    return 1
  fi
  dnf install -y "$@"
}

fh_assert_root() {
  if [ "$EUID" -ne 0 ]; then
    fh_log "This feature must run as root"
    exit 1
  fi
}

fh_mkdir_for_file() {
  local f="$1"
  mkdir -p "$(dirname "$f")"
}

export -f fh_log feature_is_installed feature_mark_installed apt_install apk_install dnf_install fh_assert_root fh_mkdir_for_file

# Ensure per-user local and cache dirs exist and are owned by the target user
# Usage: fh_ensure_user_dirs <nb_user> <nb_uid> <nb_gid> [home_dir]
fh_ensure_user_dirs() {
  local nb_user=${1:-jovyan}
  local nb_uid=${2:-1001}
  local nb_gid=${3:-1001}
  local home_dir=${4:-/home/${nb_user}}
  if [ -z "${home_dir}" ]; then
    return 0
  fi
  mkdir -p "${home_dir}/.local/bin" "${home_dir}/.cache" "${home_dir}/.cache/pip" >/dev/null 2>&1 || true
  if getent passwd "${nb_user}" >/dev/null 2>&1; then
    chown -R "${nb_uid}:${nb_gid}" "${home_dir}/.local" "${home_dir}/.cache" >/dev/null 2>&1 || true
  fi
}

export -f fh_ensure_user_dirs
