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
LOCAL_BIN="${HOME_DIR}/bin"

mkdir -p "${LOCAL_BIN}"

# resolve_version helper (prefer per-feature, then central Artefacts, then /tmp)
resolve_version() {
  local tool="$1" v=""
  if [ -f "${PWD}/Artefacts/features/${tool}/versions.json" ]; then
    v=$(jq -r --arg t "$tool" '.tools[$t] // empty' "${PWD}/Artefacts/features/${tool}/versions.json" 2>/dev/null || true)
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

GH_VERSION=$(resolve_version "gh")
if [ -z "${GH_VERSION}" ]; then
  echo "gh-cli: GH version not found in Artefacts or /tmp/versions.json, skipping" >&2
  exit 0
fi

if [ -f "${PWD}/scripts/arch.sh" ]; then
  # shellcheck source=/dev/null
  source "${PWD}/scripts/arch.sh"
  ARCH=$(arch_map "${TARGETPLATFORM:-$(uname -m)}")
else
  ARCH=$(case "$(uname -m)" in x86_64|X86_64) echo "amd64" ;; aarch64) echo "arm64" ;; *) echo "amd64" ;; esac)
fi

GH_URL="https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${ARCH}.tar.gz"

resolve_checksum() {
  local tool="$1" ver="$2" arch="$3" cs=""
  if [ -f "${PWD}/Artefacts/features/${tool}/checksums.json" ]; then
    cs=$(jq -r --arg t "$tool" --arg v "$ver" --arg a "$arch" '.tools[$t].checksums[$v][$a] // empty' "${PWD}/Artefacts/features/${tool}/checksums.json" 2>/dev/null || true)
    [ -n "$cs" ] && { echo "$cs"; return 0; }
  fi
  if [ -f "${PWD}/Artefacts/checksums.json" ]; then
    cs=$(jq -r --arg t "$tool" --arg v "$ver" --arg a "$arch" '.tools[$t].checksums[$v][$a] // empty' "${PWD}/Artefacts/checksums.json" 2>/dev/null || true)
    [ -n "$cs" ] && { echo "$cs"; return 0; }
  fi
  if [ -f /tmp/checksums.json ]; then
    cs=$(jq -r --arg t "$tool" --arg v "$ver" --arg a "$arch" '.tools[$t].checksums[$v][$a] // empty' /tmp/checksums.json 2>/dev/null || true)
    [ -n "$cs" ] && { echo "$cs"; return 0; }
  fi
  echo ""
}

CHKSUM=$(resolve_checksum "gh" "${GH_VERSION}" "${ARCH}")

echo "gh-cli: installing gh ${GH_VERSION}"
if command -v toolcache-get >/dev/null 2>&1; then
  PREFIX=$(toolcache-get "gh" "${GH_VERSION}" "${GH_URL}" "${CHKSUM}" || true)
  if [ -n "${PREFIX}" ]; then
    # find binary in cached prefix
    gh_bin=$(find "${PREFIX}" -type f -name gh -path "*/bin/gh" -print -quit 2>/dev/null || true)
    if [ -n "${gh_bin}" ]; then
      cp -a "${gh_bin}" "${LOCAL_BIN}/gh"
      chmod +x "${LOCAL_BIN}/gh" || true
      chown -R "${NB_UID}":"${NB_GID}" "${LOCAL_BIN}"
      echo "gh-cli: installed gh to ${LOCAL_BIN}/gh"
      exit 0
    fi
    # if tarball extracted into nested dir, attempt to locate
    nested=$(find "${PREFIX}" -type f -path "*/gh_${GH_VERSION}_linux_${ARCH}/bin/gh" -print -quit 2>/dev/null || true)
    if [ -n "${nested}" ]; then
      cp -a "${nested}" "${LOCAL_BIN}/gh"
      chmod +x "${LOCAL_BIN}/gh" || true
      chown -R "${NB_UID}":"${NB_GID}" "${LOCAL_BIN}"
      echo "gh-cli: installed gh to ${LOCAL_BIN}/gh"
      exit 0
    fi
  fi
  echo "gh-cli: toolcache-get did not provide binary, falling back to download" >&2
fi

# Fallback: download and verify
curl -fsSL "${GH_URL}" -o /tmp/gh.tar.gz
# Prefer centralized verification helper when available
if [ -n "${CHKSUM}" ]; then
  if command -v fh_verify_from_checksums >/dev/null 2>&1; then
    fh_verify_from_checksums "gh" "${GH_VERSION}" "${ARCH}" /tmp/gh.tar.gz || { echo "gh-cli: checksum verification failed" >&2; exit 1; }
  elif command -v verify-artifact >/dev/null 2>&1; then
    verify-artifact "${CHKSUM}" /tmp/gh.tar.gz
  else
    echo "${CHKSUM}  /tmp/gh.tar.gz" > /tmp/gh.sha256 && sha256sum -c /tmp/gh.sha256
  fi
fi
tar xz --strip-components=2 -C "${LOCAL_BIN}" -f /tmp/gh.tar.gz "gh_${GH_VERSION}_linux_${ARCH}/bin/gh"
rm -f /tmp/gh.tar.gz
chmod +x "${LOCAL_BIN}/gh" || true
  chown -R "${NB_UID}":"${NB_GID}" "${LOCAL_BIN}"
echo "gh-cli: installed gh to ${LOCAL_BIN}/gh"
