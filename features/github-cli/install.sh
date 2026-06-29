#!/usr/bin/env bash
set -euo pipefail

# Source shared feature helpers
if [ -n "${FEATURE_HELPERS_DIR:-}" ] && [ -f "${FEATURE_HELPERS_DIR}/helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "${FEATURE_HELPERS_DIR}/helpers.sh"
elif [ -f "../../../scripts/lib/features.sh" ]; then
  # shellcheck disable=SC1091
  source "../../../scripts/lib/features.sh"
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

# Resolve version from Artefacts (check common mounted paths)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
resolve_version() {
  local tool="$1" v=""
  read_tool_from_json() {
    local file="$1" t="$2"
    if [ ! -f "$file" ]; then echo ""; return 0; fi
    if command -v jq >/dev/null 2>&1; then
      jq -r --arg t "$t" '.tools[$t] // empty' "$file" 2>/dev/null || true
      return 0
    fi
    grep -E "\"$t\"[[:space:]]*:[[:space:]]*\"[^\"]+\"" "$file" 2>/dev/null | sed -E 's/.*:[[:space:]]*"(.*)".*/\1/' | head -n1 || true
  }

  # Check repository-mounted Artefacts
  if [ -f "${PWD}/Artefacts/versions.json" ]; then
    v=$(read_tool_from_json "${PWD}/Artefacts/versions.json" "$tool")
    [ -n "$v" ] && { echo "$v"; return 0; }
  fi
    # prefer centralized resolver
    if command -v fh_resolve_version >/dev/null 2>&1; then
      v=$(fh_resolve_version "$tool" || true)
      if [ -n "$v" ]; then
        echo "$v"
        return 0
      fi
    fi

  # Check feature-scoped Artefacts
  if [ -f "${PWD}/artefacts/${tool}/versions.json" ]; then
    v=$(read_tool_from_json "${PWD}/artefacts/${tool}/versions.json" "$tool")
    [ -n "$v" ] && { echo "$v"; return 0; }
  fi

  # Check script-relative Artefacts (when mounted into /tmp during build)
  if [ -f "${SCRIPT_DIR}/../../Artefacts/versions.json" ]; then
    v=$(read_tool_from_json "${SCRIPT_DIR}/../../Artefacts/versions.json" "$tool")
    [ -n "$v" ] && { echo "$v"; return 0; }
  fi

  # Check /tmp/Artefacts and /tmp/versions.json (common build mounts)
  if [ -f "/tmp/Artefacts/versions.json" ]; then
    v=$(read_tool_from_json "/tmp/Artefacts/versions.json" "$tool")
    [ -n "$v" ] && { echo "$v"; return 0; }
  fi
  if [ -f "/tmp/versions.json" ]; then
    v=$(read_tool_from_json "/tmp/versions.json" "$tool")
    [ -n "$v" ] && { echo "$v"; return 0; }
  fi

  echo ""
}

GH_VERSION=$(resolve_version "gh")
if [ -z "${GH_VERSION}" ]; then
  echo "⚠️  gh-cli: Version not found in Artefacts, using latest"
  GH_VERSION="latest"
fi

echo "📦 Installing GitHub CLI version: ${GH_VERSION}"

# Resolve architecture using shared helper function if present
if command -v _map_architecture >/dev/null 2>&1; then
  ARCH=$(_map_architecture)
else
  ARCH=$(case "$(uname -m)" in x86_64|X86_64) echo "amd64" ;; aarch64|arm64) echo "arm64" ;; *) echo "amd64" ;; esac)
fi

# Use pattern with placeholders - the download helper will substitute {version} and {arch}
PATTERN="gh_{version}_linux_{arch}.tar.gz"

# Use shared download helper with pattern
download_github_release "cli/cli" "gh" "${GH_VERSION}" "${LOCAL_BIN}" "${PATTERN}"

# Set ownership
chown -R "${NB_UID}":"${NB_GID}" "${LOCAL_BIN}" 2>/dev/null || true

echo "✅ GitHub CLI installed successfully to ${LOCAL_BIN}/gh"
echo "===================================================================="
