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
TEXDIR="${HOME_DIR}/.TinyTeX"
INSTALLER="installer-unix"
TINYTEX_VERSION="2025.05"

# Pin CTAN repository to a France mirror by default to avoid auto mirror selection.
# User-provided mirrors (preferred):
# - https://ctan.ceremade.dauphine.fr (Paris)
# - https://ctan.mines-albi.fr (Albi)
# - https://ctan.tetaneutral.net (Toulouse)
# - https://distrib-coffee.ipsl.jussieu.fr (Paris)
# Default to ceremade.dauphine.fr for TLS/https access; can be overridden by setting CTAN_REPO env var.
CTAN_REPO="${CTAN_REPO:-https://ctan.ceremade.dauphine.fr/systems/texlive/tlnet}"

# Resolve version helper (prefer per-feature artefacts/*, then central, then /tmp)
resolve_version() {
  local tool="$1" v=""
  # Prefer centralized helper when available
  if command -v fh_resolve_version >/dev/null 2>&1; then
    v=$(fh_resolve_version "$tool" || true)
    [ -n "$v" ] && { echo "$v"; return 0; }
  fi

  # Check repository-local artefacts (case-insensitive artefacts/artefacts)
  if [ -f "${PWD}/artefacts/${tool}/versions.json" ]; then
    v=$(jq -r --arg t "$tool" '.tools[$t] // empty' "${PWD}/artefacts/${tool}/versions.json" 2>/dev/null || true)
    [ -n "$v" ] && { echo "$v"; return 0; }
  fi
  if [ -f "${PWD}/artefacts/versions.json" ]; then
    v=$(jq -r --arg t "$tool" '.tools[$t] // empty' "${PWD}/artefacts/versions.json" 2>/dev/null || true)
    [ -n "$v" ] && { echo "$v"; return 0; }
  fi

  # Check shared /tmp artefacts used during Docker generation
  if [ -f /tmp/versions.json ]; then
    v=$(jq -r --arg t "$tool" '.tools[$t] // empty' /tmp/versions.json 2>/dev/null || true)
    [ -n "$v" ] && { echo "$v"; return 0; }
  fi

  echo ""
}

TMP_VER=$(resolve_version "tinytex")
if [ -n "${TMP_VER}" ]; then
  TINYTEX_VERSION="${TMP_VER}"
fi
TINYTEX_URL="https://github.com/rstudio/tinytex-releases/releases/download/v${TINYTEX_VERSION}/${INSTALLER}-v${TINYTEX_VERSION}.tar.gz"

echo "texlive: installing TinyTeX (this may be large)"
if [ ! -f /tmp/TeXLive ]; then
  echo "texlive: no prebuilt /tmp/TeXLive artefact found; proceeding with direct download/install" >&2
fi
resolve_checksum() {
  local tool="$1" ver="$2" arch="$3" cs=""
  # Require centralized resolver as single source of truth
  if ! command -v fh_resolve_checksum >/dev/null 2>&1; then
    echo "texlive: fh_resolve_checksum not available; checksum resolution required" >&2
    return 2
  fi
  cs=$(fh_resolve_checksum "$tool" "$ver" || true)
  if [ -z "${cs}" ]; then
    echo "texlive: checksum not found for ${tool} ${ver} via fh_resolve_checksum" >&2
    return 3
  fi
  echo "$cs"
}

# Download TinyTeX installer using shared helper
tmpd=$(mktemp -d)
# Download to a directory so the downloader can extract into a predictable tree
if download_direct \
  "${TINYTEX_URL}" \
  "tinytex" \
  "${tmpd}" \
  false; then
  # download_direct will copy the downloaded archive to ${tmpd}/tinytex
  if [ -f "${tmpd}/tinytex" ]; then
    mkdir -p "${tmpd}/extracted"
    tar -xzf "${tmpd}/tinytex" -C "${tmpd}/extracted" || true
    rm -f "${tmpd}/tinytex"
    # look for install.sh under extracted tree
    installer_sh=""
    if [ -f "${tmpd}/extracted/install.sh" ]; then
      installer_sh="${tmpd}/extracted/install.sh"
    else
      for d in "${tmpd}/extracted"/*; do
        if [ -f "$d/install.sh" ]; then
          installer_sh="$d/install.sh"
          break
        fi
      done
    fi
  fi
else
  installer_sh=""
fi

# If an installer script was produced by extraction, run it; otherwise fall back
# to direct curl + verification path used historically.
installer_sh=""
if [ -f "${tmpd}/install.sh" ]; then
  installer_sh="${tmpd}/install.sh"
else
  # look for install.sh under any top-level extracted directory
  for d in "${tmpd}"/*; do
    if [ -f "$d/install.sh" ]; then
      installer_sh="$d/install.sh"
      break
    fi
  done
fi

if [ -n "${installer_sh}" ]; then
  # Ensure system libraries required by TeX engines are present
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || true
    apt-get install -y --no-install-recommends \
      fontconfig libfontconfig1 libfreetype6 libx11-6 libxrender1 libxext6 fonts-dejavu-core \
      ca-certificates >/dev/null 2>&1 || true
    rm -rf /var/lib/apt/lists/* || true
  fi

  pushd "$(dirname "${installer_sh}")"
  ./install.sh || true
  popd
  rm -rf "${tmpd}"
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
