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

NB_USER=${NB_USER:-jovyan}
NB_UID=${NB_UID:-1001}
NB_GID=${NB_GID:-1001}
HOME_DIR="/home/${NB_USER}"
LOCAL_BIN="${HOME_DIR}/bin"

mkdir -p "${LOCAL_BIN}"

# Resolve k9s version
if [ -f "${PWD}/artefacts/kubernetes-dev/versions.json" ] || [ -f "${PWD}/Artefacts/versions.json" ] || [ -f /tmp/versions.json ]; then
  resolve_version() {
    local tool="$1" v=""
    if [ -f "${PWD}/artefacts/kubernetes-dev/versions.json" ]; then
      v=$(jq -r --arg t "$tool" '.tools[$t] // empty' "${PWD}/artefacts/kubernetes-dev/versions.json" 2>/dev/null || true)
      [ -n "$v" ] && { echo "$v"; return 0; }
    fi
    if [ -f "${PWD}/Artefacts/versions.json" ]; then
      v=$(jq -r --arg t "$tool" '.tools[$t] // empty' "${PWD}/Artefacts/versions.json" 2>/dev/null || true)
      [ -n "$v" ] && { echo "$v"; return 0; }
    fi
    if [ -f /tmp/versions.json ]; then
      v=$(jq -r --arg t "$tool" '.tools[$t] // empty' /tmp/versions.json 2>/dev/null || true)
      [ -n "$v" ] && { echo "$v"; return 0; }
    fi
    echo ""
  }

  # prefer centralized resolver
  if command -v fh_resolve_version >/dev/null 2>&1; then
    v=$(fh_resolve_version "$tool" || true)
    if [ -n "$v" ]; then
      echo "$v"; return 0
    fi
  fi
  K9S_VERSION=$(resolve_version "k9s")
else
  echo "kubernetes-dev: no versions.json found, skipping" >&2
  exit 0
fi

# Install k9s (GitHub release tarball)
if [ -n "${K9S_VERSION}" ]; then
  echo "kubernetes-dev: installing k9s ${K9S_VERSION}"
  # Compute ARCH mapping used by k9s filenames (amd64/arm64)
  arch_raw=$(uname -m)
  case "$arch_raw" in
    x86_64|X86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    armv7*|armhf) ARCH=arm ;;
    *) ARCH="$arch_raw" ;;
  esac

  # Ensure tag includes leading 'v' for the release path (e.g. v0.50.18)
  if [[ "${K9S_VERSION}" == v* ]]; then
    K9S_TAG="${K9S_VERSION}"
  else
    K9S_TAG="v${K9S_VERSION}"
  fi

  K9S_URL="https://github.com/derailed/k9s/releases/download/${K9S_TAG}/k9s_Linux_${ARCH}.tar.gz"
  download_direct "${K9S_URL}" "k9s" "${LOCAL_BIN}" "true"
fi

chown -R ${NB_UID}:${NB_GID} "${LOCAL_BIN}" || true
echo "kubernetes-dev: installed k9s into ${LOCAL_BIN}"
