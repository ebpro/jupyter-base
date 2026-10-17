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
  mkdir -p "${HOME_DIR}/.local/bin" "${HOME_DIR}/.cache" >/dev/null 2>&1 || true
  chown -R ${NB_UID:-1001}:${NB_GID:-1001} "${HOME_DIR}/.local" "${HOME_DIR}/.cache" >/dev/null 2>&1 || true
fi

NB_USER=${NB_USER:-jovyan}
NB_UID=${NB_UID:-1001}
NB_GID=${NB_GID:-1001}
HOME_DIR="/home/${NB_USER}"

echo "code-server: installing code-server runtime"

resolve_version() {
  local tool="$1" v=""
  # prefer centralized resolver (reaches /tmp/artefacts/versions.json and /opt/solen/artefacts/versions.json)
  if command -v fh_resolve_version >/dev/null 2>&1; then
    v=$(fh_resolve_version "$tool" || true)
    if [ -n "$v" ]; then
      echo "$v"; return 0
    fi
  fi
  if [ -f "${PWD}/artefacts/versions.json" ]; then
    v=$(jq -r --arg t "$tool" '.tools[$t] // empty' "${PWD}/artefacts/versions.json" 2>/dev/null || true)
    [ -n "$v" ] && { echo "$v"; return 0; }
  fi
  if [ -f /tmp/versions.json ]; then
    v=$(jq -r --arg t "$tool" '.tools[$t] // empty' /tmp/versions.json 2>/dev/null || true)
    [ -n "$v" ] && { echo "$v"; return 0; }
  fi
  echo ""
}

CODE_SERVER_VERSION=$(resolve_version "code-server")
if [ -z "${CODE_SERVER_VERSION}" ]; then
  echo "code-server: version not found in artefacts or /tmp/versions.json; skipping" >&2
  exit 0
fi

# download_github_release builds the release tag URL as "v${version}"
# (features/_lib/download-release/install.sh:430), so the version must be
# passed de-v'd here; passing the leading v would request tag "vv4.108.0".
CODE_SERVER_VERSION="${CODE_SERVER_VERSION#v}"

echo "code-server: installing code-server ${CODE_SERVER_VERSION}"

# Download and extract code-server using helper (documented positional form:
# repo tool version install_dir filename_pattern).
# Assets are code-server-<ver>-linux-<arch>.tar.gz with arch tokens amd64/arm64;
# the archive extracts under code-server-<ver>-linux-<arch>/ with a bin/ subdir,
# which download_github_release flattens into install_dir.
mkdir -p /opt/code-server
download_github_release \
  "coder/code-server" \
  "code-server" \
  "${CODE_SERVER_VERSION}" \
  "/opt/code-server" \
  "code-server-{version}-linux-{arch}.tar.gz"

ln -sf /opt/code-server/code-server /usr/local/bin/code-server || true
chown -R "${NB_UID}":"${NB_GID}" /opt/code-server || true

echo "code-server: installed to /opt/code-server"
exit 0
