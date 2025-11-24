#!/usr/bin/env bash
set -euo pipefail

NB_USER=${NB_USER:-jovyan}
NB_UID=${NB_UID:-1001}
NB_GID=${NB_GID:-1001}
HOME_DIR="/home/${NB_USER}"
CONDA_DIR="${CONDA_DIR:-${HOME_DIR}/miniforge3}"

echo "python-conda: installing Miniforge into ${CONDA_DIR} if missing"

# Helper to resolve a tool version from per-feature artefacts, central Artefacts, or /tmp
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

# Determine miniforge version from artefacts or fall back to 'latest'
MINIFORGE_VER="$(resolve_version "miniforge")"
if [ -z "${MINIFORGE_VER}" ]; then
  MINIFORGE_VER="latest"
fi

if [ ! -x "${CONDA_DIR}/bin/conda" ]; then
  # Normalize download arch (Miniforge asset names use uname -m style aliases like x86_64/aarch64)
  if [ -f "${PWD}/scripts/arch.sh" ]; then
    # shellcheck source=/dev/null
    source "${PWD}/scripts/arch.sh"
    CANON_ARCH=$(arch_map "$(uname -m)")
    # pick a download-friendly alias if available (e.g. amd64 -> x86_64, arm64 -> aarch64)
    ALIASES=$(arch_aliases "$CANON_ARCH")
    # prefer second token when present (common mapping), else first
    read -r A1 A2 _ <<< "$ALIASES"
    if [ -n "$A2" ]; then
      DL_ARCH="$A2"
    else
      DL_ARCH="$A1"
    fi
  else
    DL_ARCH="$(uname -m)"
  fi
  installer_url="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-$(uname)-${DL_ARCH}.sh"
  # attempt to find checksum for this OS/ARCH combination
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

  ARCH_STR="$(uname)-$(uname -m)"
  # Try canonical/downloader arch first, then fallback to uname-based ARCH_STR
  CHKSUM=$(resolve_checksum "miniforge" "${MINIFORGE_VER}" "${DL_ARCH}")
  if [ -z "$CHKSUM" ]; then
    CHKSUM=$(resolve_checksum "miniforge" "${MINIFORGE_VER}" "${ARCH_STR}")
  fi

  if command -v toolcache-get >/dev/null 2>&1; then
    PREFIX=$(toolcache-get "miniforge" "${MINIFORGE_VER}" "${installer_url}" "${CHKSUM}" || true)
    if [ -n "${PREFIX}" ] && [ -f "${PREFIX}/bin/$(basename ${installer_url})" ]; then
      installer_path="${PREFIX}/bin/$(basename ${installer_url})"
    elif [ -n "${PREFIX}" ] && [ -f "${PREFIX}/$(basename ${installer_url})" ]; then
      installer_path="${PREFIX}/$(basename ${installer_url})"
    else
      installer_path="/tmp/miniforge.sh"
      curl -sL "${installer_url}" -o "${installer_path}"
      if [ -n "${CHKSUM}" ]; then
        if command -v verify-artifact >/dev/null 2>&1; then
          verify-artifact "${CHKSUM}" "${installer_path}"
        else
          echo "${CHKSUM}  ${installer_path}" > "${installer_path}.sha256" && sha256sum -c "${installer_path}.sha256" && rm -f "${installer_path}.sha256"
        fi
      fi
    fi
  else
    installer_path="/tmp/miniforge.sh"
    curl -sL "${installer_url}" -o "${installer_path}"
    if [ -n "${CHKSUM}" ]; then
      if command -v verify-artifact >/dev/null 2>&1; then
        verify-artifact "${CHKSUM}" "${installer_path}"
      else
        echo "${CHKSUM}  ${installer_path}" > "${installer_path}.sha256" && sha256sum -c "${installer_path}.sha256" && rm -f "${installer_path}.sha256"
      fi
    fi
  fi

  bash "${installer_path}" -b -p "${CONDA_DIR}"
  rm -f "${installer_path}" || true
fi

# Initialize conda for shells (idempotent)
export PATH="${CONDA_DIR}/bin:${PATH}"
set +u
source "${CONDA_DIR}/etc/profile.d/conda.sh" 2>/dev/null || true
set -u
conda init zsh || true
conda init bash || true

# If a bind-mounted /tmp/environment.yml exists, update base env
if [ -f /tmp/environment.yml ]; then
  echo "python-conda: updating base environment from /tmp/environment.yml"
  mamba env update -n base -f /tmp/environment.yml || true
fi

chown -R ${NB_UID}:${NB_GID} "${CONDA_DIR}" || true
echo "python-conda: done"
