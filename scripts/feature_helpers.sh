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
  for i in 1 2 3; do
    if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"; then
      return 0
    fi
    sleep 1
  done
  return 1
}
