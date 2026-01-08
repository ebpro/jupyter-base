#!/usr/bin/env bash
# Helper functions for feature install scripts
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

# Lookup checksum and verify a file using repository checksums.json or /tmp/checksums.json.
# Usage: fh_verify_from_checksums <tool> <version> <arch> <file>
fh_verify_from_checksums() {
  local tool=${1:-}
  local ver=${2:-}
  local arch=${3:-}
  local file=${4:-}
  if [ -z "$tool" ] || [ -z "$ver" ] || [ -z "$arch" ] || [ -z "$file" ]; then
    fh_log "fh_verify_from_checksums requires 4 args: tool version arch file"
    return 2
  fi

  local checksums
  if [ -f /tmp/checksums.json ]; then
    checksums=/tmp/checksums.json
  elif [ -f "${PWD}/Artefacts/checksums.json" ]; then
    checksums="${PWD}/Artefacts/checksums.json"
  else
    fh_log "No checksums.json found (/tmp/checksums.json or Artefacts/checksums.json)"
    return 3
  fi

  if ! command -v jq >/dev/null 2>&1; then
    fh_log "jq not available; cannot lookup checksum in ${checksums}"
    return 4
  fi

  local sha
  sha=$(jq -r --arg t "$tool" --arg ver "$ver" --arg arch "$arch" '.tools[$t].checksums[$ver][$arch] // empty' "$checksums" 2>/dev/null || true)
  if [ -z "$sha" ]; then
    fh_log "Checksum missing for ${tool}@${ver} ${arch} in ${checksums}"
    return 5
  fi

  # If a verify-from-checksums helper is available, use it (it handles file lookup).
  if command -v verify-from-checksums >/dev/null 2>&1; then
    verify-from-checksums "$tool" "$ver" "$arch" "$file"
    return $?
  fi

  # Fallback to verify-artifact if present
  if command -v verify-artifact >/dev/null 2>&1; then
    verify-artifact "$sha" "$file"
    return $?
  fi

  # Final fallback: write temporary sha file and run sha256sum -c
  local tmp
  tmp=$(mktemp)
  echo "$sha  $file" > "$tmp"
  sha256sum -c "$tmp"
  local rc=$?
  rm -f "$tmp"
  return $rc
}

export -f fh_verify_from_checksums

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

# Safely chown paths only when running as root
fh_safe_chown() {
  local uid=${1:-}
  local gid=${2:-}
  shift 2 || true
  local paths=("$@")
  if [ -z "$uid" ] || [ -z "$gid" ] || [ ${#paths[@]} -eq 0 ]; then
    fh_log "fh_safe_chown requires: uid gid path..."
    return 2
  fi
  if [ "$(id -u)" -eq 0 ]; then
    chown -R "${uid}:${gid}" "${paths[@]}" >/dev/null 2>&1 || true
  else
    fh_log "Not running as root; skipping chown ${paths[*]}"
  fi
}

export -f fh_safe_chown
#!/usr/bin/env bash
set -euo pipefail

# Helper functions for feature install scripts
# Usage: source /path/to/scripts/feature_helpers.sh

FEATURE_MARKER_DIR="/opt/.features"

fh_log() {
  printf "[feature:%s] %s\n" "${FEATURE_ID:-unknown}" "$*"
}

feature_is_installed() {
  local id=${FEATURE_ID:-}
  local ver=${FEATURE_VERSION:-}
  [ -z "$id" ] && return 1
  local marker="$FEATURE_MARKER_DIR/${id}-${ver}"
  [ -f "$marker" ]
}

feature_mark_installed() {
  local id=${FEATURE_ID:-}
  local ver=${FEATURE_VERSION:-}
  mkdir -p "$FEATURE_MARKER_DIR"
  touch "$FEATURE_MARKER_DIR/${id}-${ver}"
}

# Safe apt-install wrapper: retries transient failures
apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update || true
  for _ in 1 2 3; do
    if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"; then
      return 0
    fi
    sleep 1
  done
  return 1
}
