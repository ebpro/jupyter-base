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
TEXDIR="${HOME_DIR}/.TinyTeX"
INSTALLER="installer-unix"
TINYTEX_VERSION="2025.05"

# Resolve version helper (prefer per-feature Artefacts/features/*, then central, then /tmp)
resolve_version() {
  local tool="$1" v=""
  if [ -f "${PWD}/Artefacts/features/${tool}/versions.json" ]; then
    v=$(jq -r --arg t "$tool" '.tools[$t] // .tools["${tool}" ] // empty' "${PWD}/Artefacts/features/${tool}/versions.json" 2>/dev/null || true)
    [ -n "$v" ] && { echo "$v"; return 0; }
  fi
  if [ -f "${PWD}/Artefacts/versions.json" ]; then
    v=$(jq -r --arg t "$tool" '.tools[$t] // .tools["${tool}" ] // empty' "${PWD}/Artefacts/versions.json" 2>/dev/null || true)
    [ -n "$v" ] && { echo "$v"; return 0; }
  fi
  if [ -f /tmp/versions.json ]; then
    v=$(jq -r --arg t "$tool" '.tools[$t] // .tools["${tool}" ] // empty' /tmp/versions.json 2>/dev/null || true)
    [ -n "$v" ] && { echo "$v"; return 0; }
  fi
  echo ""
}

TMP_VER=$(resolve_version "tinytex")
if [ -n "${TMP_VER}" ]; then
  TINYTEX_VERSION="${TMP_VER}"
fi
TINYTEX_URL="https://github.com/rstudio/tinytex-releases/releases/download/v${TINYTEX_VERSION}/${INSTALLER}-v${TINYTEX_VERSION}.tar.gz"

if [ ! -f /tmp/TeXLive ]; then
  echo "texlive: /tmp/TeXLive not present; skipping heavy install" >&2
  exit 0
fi

echo "texlive: installing TinyTeX (this may be large)"
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

CHKSUM=$(resolve_checksum "tinytex" "${TINYTEX_VERSION}" "${ARCH:-linux}")
if [ -z "${CHKSUM}" ]; then
  CHKSUM=$(resolve_checksum "tinytex-installer" "${TINYTEX_VERSION}" "${ARCH:-linux}")
fi

if command -v toolcache-get >/dev/null 2>&1; then
  PREFIX=$(toolcache-get "tinytex-installer" "${TINYTEX_VERSION}" "${TINYTEX_URL}" "${CHKSUM}" || true)
  if [ -n "${PREFIX}" ]; then
    # find install script inside prefix
    inst=$(find "${PREFIX}" -type f -name install.sh -print -quit 2>/dev/null || true)
    if [ -n "${inst}" ]; then
      tmpd=$(mktemp -d)
      cp -a "${PREFIX}"/* "${tmpd}/" || true
      pushd "${tmpd}"
      ./install.sh || true
      popd
      rm -rf "${tmpd}"
    fi
  else
    echo "texlive: toolcache-get failed, falling back to direct download"
    curl -fsSL "${TINYTEX_URL}" -o /tmp/${INSTALLER}.tar.gz
    if command -v fh_verify_from_checksums >/dev/null 2>&1; then
      if fh_verify_from_checksums "tinytex" "${TINYTEX_VERSION}" "${ARCH:-linux}" /tmp/${INSTALLER}.tar.gz; then
        :
      elif fh_verify_from_checksums "tinytex-installer" "${TINYTEX_VERSION}" "${ARCH:-linux}" /tmp/${INSTALLER}.tar.gz; then
        :
      else
        echo "texlive: checksum verification failed" >&2
        exit 1
      fi
    else
      if [ -n "${CHKSUM}" ] && command -v verify-artifact >/dev/null 2>&1; then
        verify-artifact "${CHKSUM}" /tmp/${INSTALLER}.tar.gz
      elif [ -n "${CHKSUM}" ]; then
        echo "${CHKSUM}  /tmp/${INSTALLER}.tar.gz" > /tmp/${INSTALLER}.sha256 && sha256sum -c /tmp/${INSTALLER}.sha256 && rm -f /tmp/${INSTALLER}.sha256
      fi
    fi
    tar xf /tmp/${INSTALLER}.tar.gz -C /tmp
    pushd /tmp
    ./install.sh || true
    popd
    rm -f /tmp/${INSTALLER}.tar.gz || true
  fi
else
  curl -fsSL "${TINYTEX_URL}" -o /tmp/${INSTALLER}.tar.gz
  if command -v fh_verify_from_checksums >/dev/null 2>&1; then
    if fh_verify_from_checksums "tinytex" "${TINYTEX_VERSION}" "${ARCH:-linux}" /tmp/${INSTALLER}.tar.gz; then
      :
    elif fh_verify_from_checksums "tinytex-installer" "${TINYTEX_VERSION}" "${ARCH:-linux}" /tmp/${INSTALLER}.tar.gz; then
      :
    else
      echo "texlive: checksum verification failed" >&2
      exit 1
    fi
  else
    if [ -n "${CHKSUM}" ] && command -v verify-artifact >/dev/null 2>&1; then
      verify-artifact "${CHKSUM}" /tmp/${INSTALLER}.tar.gz
    elif [ -n "${CHKSUM}" ]; then
      echo "${CHKSUM}  /tmp/${INSTALLER}.tar.gz" > /tmp/${INSTALLER}.sha256 && sha256sum -c /tmp/${INSTALLER}.sha256 && rm -f /tmp/${INSTALLER}.sha256
    fi
  fi
  tar xf /tmp/${INSTALLER}.tar.gz -C /tmp
  pushd /tmp
  ./install.sh || true
  popd
  rm -f /tmp/${INSTALLER}.tar.gz || true
fi
mkdir -p "${TEXDIR}"
mv texlive/* "${TEXDIR}" || true
rm -rf texlive || true

# Configure tlmgr repository from Dockerfile default if present
if [ -n "${CTAN_REPO:-}" ]; then
  for tl in "${TEXDIR}"/bin/*/tlmgr; do
    if [ -x "${tl}" ]; then
      "${tl}" option repository "${CTAN_REPO}" || true
    fi
  done
fi

chown -R "${NB_UID}":"${NB_GID}" "${TEXDIR}" || true
echo "texlive: done"
