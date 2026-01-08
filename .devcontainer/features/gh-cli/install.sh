#!/usr/bin/env bash
set -euo pipefail

# Source shared feature helpers
if [ -n "${FEATURE_HELPERS_DIR:-}" ] && [ -f "${FEATURE_HELPERS_DIR}/helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "${FEATURE_HELPERS_DIR}/helpers.sh"
elif [ -f "../../../scripts/feature_helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "../../../scripts/feature_helpers.sh"
fi

# Source download helper
if [ -f "/usr/local/lib/download-release-helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "/usr/local/lib/download-release-helpers.sh"
else
  echo "❌ gh-cli: download-release helper not found, ensure _lib/download-release is installed first"
  exit 1
fi

# Ensure per-user local/cache dirs exist
if command -v fh_ensure_user_dirs >/dev/null 2>&1; then
  fh_ensure_user_dirs "${NB_USER:-jovyan}" "${NB_UID:-1001}" "${NB_GID:-1001}" || true
else
  HOME_DIR=${HOME_DIR:-/home/${NB_USER:-jovyan}}
  mkdir -p "${HOME_DIR}/.local/bin" "${HOME_DIR}/.cache" >/dev/null 2>&1 || true
  chown -R ${NB_UID:-1001}:${NB_GID:-1001} "${HOME_DIR}/.local" "${HOME_DIR}/.cache" >/dev/null 2>&1 || true
fi

echo "===================================================================="
echo "Feature: GitHub CLI (gh)"
echo "===================================================================="

NB_USER=${NB_USER:-jovyan}
NB_UID=${NB_UID:-1001}
NB_GID=${NB_GID:-1001}
HOME_DIR="/home/${NB_USER}"
LOCAL_BIN="${HOME_DIR}/bin"

mkdir -p "${LOCAL_BIN}"

# Resolve version from Artefacts
resolve_version() {
  local tool="$1" v=""
  if [ -f "${PWD}/Artefacts/versions.json" ]; then
    v=$(jq -r --arg t "$tool" '.tools[$t] // empty' "${PWD}/Artefacts/versions.json" 2>/dev/null || true)
  elif [ -f /tmp/versions.json ]; then
    v=$(jq -r --arg t "$tool" '.tools[$t] // empty' /tmp/versions.json 2>/dev/null || true)
  fi
  echo "$v"
}

GH_VERSION=$(resolve_version "gh")
if [ -z "${GH_VERSION}" ]; then
  echo "⚠️  gh-cli: Version not found in Artefacts, using latest"
  GH_VERSION="latest"
fi

echo "📦 Installing GitHub CLI version: ${GH_VERSION}"

# Use shared download helper
download_github_release "cli/cli" "gh" "${GH_VERSION}" "${LOCAL_BIN}"

# Set ownership
chown -R "${NB_UID}":"${NB_GID}" "${LOCAL_BIN}" 2>/dev/null || true

echo "✅ GitHub CLI installed successfully to ${LOCAL_BIN}/gh"
echo "===================================================================="
