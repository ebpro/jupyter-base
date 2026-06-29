# Auto-inserted by scripts/inject_prebaked_helpers.sh
# Source shared feature helpers (prebaked into image) or fall back to repository helper
# Ensure per-user local/cache dirs exist (use helper when available, fallback otherwise)
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

# Default notebook user variables early so helper calls can rely on them
NB_USER=${NB_USER:-jovyan}
NB_UID=${NB_UID:-1001}
NB_GID=${NB_GID:-1001}
HOME_DIR=${HOME_DIR:-/home/${NB_USER}}
# Ensure per-user local/cache dirs exist (use helper when available, fallback otherwise)
if command -v fh_ensure_user_dirs >/dev/null 2>&1; then
  fh_ensure_user_dirs "${NB_USER:-jovyan}" "${NB_UID:-1001}" "${NB_GID:-1001}" || true
else
  mkdir -p "${HOME_DIR}/.local/bin" "${HOME_DIR}/.cache" "${HOME_DIR}/.cache/pip" >/dev/null 2>&1 || true
  chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/.local" "${HOME_DIR}/.cache" >/dev/null 2>&1 || true
fi

# Ensure IPython dir exists and is owned by the notebook user to avoid runtime warnings
mkdir -p "${HOME_DIR}/.ipython" >/dev/null 2>&1 || true
chown -R ${NB_UID:-1001}:${NB_GID:-1001} "${HOME_DIR}/.ipython" >/dev/null 2>&1 || true

CONDA_DIR="${CONDA_DIR:-${HOME_DIR}/miniforge3}"

echo "python-conda: installing Miniforge into ${CONDA_DIR} if missing"

# Helper to resolve a tool version from per-feature artefacts, central Artefacts, or /tmp
resolve_version() {
  local tool="$1" v=""
    # prefer centralized resolver
    if command -v fh_resolve_version >/dev/null 2>&1; then
      v=$(fh_resolve_version "$tool" || true)
      if [ -n "$v" ]; then
        echo "$v"; return 0
      fi
    fi
    if [ -f "${PWD}/artefacts/${tool}/versions.json" ]; then
      v=$(jq -r --arg t "$tool" '.tools[$t] // empty' "${PWD}/artefacts/${tool}/versions.json" 2>/dev/null || true)
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

  # Construct URL using pinned version if available, otherwise fall back to latest
  if [ "${MINIFORGE_VER}" != "latest" ]; then
    installer_url="https://github.com/conda-forge/miniforge/releases/download/${MINIFORGE_VER}/Miniforge3-$(uname)-${DL_ARCH}.sh"
  else
    installer_url="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-$(uname)-${DL_ARCH}.sh"
  fi

  # attempt to find checksum for this OS/ARCH combination
  resolve_checksum() {
    local tool="$1" ver="$2" arch="$3" cs=""
     # Require centralized resolver as single source of truth
     if ! command -v fh_resolve_checksum >/dev/null 2>&1; then
       echo "python-conda: fh_resolve_checksum not available; checksum resolution required" >&2
       return 2
     fi
     cs=$(fh_resolve_checksum "$tool" "$ver" || true)
     if [ -z "${cs}" ]; then
       echo "python-conda: checksum not found for ${tool} ${ver} via fh_resolve_checksum" >&2
       return 3
     fi
     echo "$cs"
  }

  ARCH_STR="$(uname)-$(uname -m)"
  # Try canonical/downloader arch first, then fallback to uname-based ARCH_STR
  CHKSUM=$(resolve_checksum "miniforge" "${MINIFORGE_VER}" "${DL_ARCH}")
  if [ -z "$CHKSUM" ]; then
    CHKSUM=$(resolve_checksum "miniforge" "${MINIFORGE_VER}" "${ARCH_STR}")
  fi

  if command -v toolcache-get >/dev/null 2>&1; then
    PREFIX=$(toolcache-get "miniforge" "${MINIFORGE_VER}" "${installer_url}" "${CHKSUM}" || true)
    if [ -n "${PREFIX}" ] && [ -f "${PREFIX}/bin/$(basename "${installer_url}")" ]; then
      installer_path="${PREFIX}/bin/$(basename "${installer_url}")"
    elif [ -n "${PREFIX}" ] && [ -f "${PREFIX}/$(basename "${installer_url}")" ]; then
      installer_path="${PREFIX}/$(basename "${installer_url}")"
    else
      installer_path="/tmp/miniforge.sh"
      curl -sL "${installer_url}" -o "${installer_path}"
      if command -v fh_verify_from_checksums >/dev/null 2>&1; then
        # Try both canonical downloader arch and uname-based ARCH_STR
        if fh_verify_from_checksums "miniforge" "${MINIFORGE_VER}" "${DL_ARCH}" "${installer_path}" || fh_verify_from_checksums "miniforge" "${MINIFORGE_VER}" "${ARCH_STR}" "${installer_path}"; then
          :
        else
          echo "python-conda: checksum verification failed" >&2
          exit 1
        fi
      else
        if [ -n "${CHKSUM}" ]; then
          if command -v verify-artifact >/dev/null 2>&1; then
            verify-artifact "${CHKSUM}" "${installer_path}"
          else
            echo "${CHKSUM}  ${installer_path}" > "${installer_path}.sha256" && sha256sum -c "${installer_path}.sha256" && rm -f "${installer_path}.sha256"
          fi
        fi
      fi
    fi
  else
    installer_path="/tmp/miniforge.sh"
    curl -sL "${installer_url}" -o "${installer_path}"
    if command -v fh_verify_from_checksums >/dev/null 2>&1; then
      if fh_verify_from_checksums "miniforge" "${MINIFORGE_VER}" "${DL_ARCH}" "${installer_path}" || fh_verify_from_checksums "miniforge" "${MINIFORGE_VER}" "${ARCH_STR}" "${installer_path}"; then
        :
      else
        echo "python-conda: checksum verification failed" >&2
        exit 1
      fi
    else
      if [ -n "${CHKSUM}" ]; then
        if command -v verify-artifact >/dev/null 2>&1; then
          verify-artifact "${CHKSUM}" "${installer_path}"
        else
          echo "${CHKSUM}  ${installer_path}" > "${installer_path}.sha256" && sha256sum -c "${installer_path}.sha256" && rm -f "${installer_path}.sha256"
        fi
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
# Run conda init as the non-root user to avoid creating root-owned dotfiles
if [ -d "${HOME_DIR}" ] && id -u "${NB_USER}" >/dev/null 2>&1; then
  TMP_SCRIPT="/tmp/conda-init-${NB_USER}.sh"
  cat > "${TMP_SCRIPT}" <<BASH
#!/usr/bin/env bash
set -euo pipefail
"${CONDA_DIR}/bin/conda" init zsh || true
"${CONDA_DIR}/bin/conda" init bash || true
BASH
  chmod +x "${TMP_SCRIPT}" || true
  su - ${NB_USER} -s /bin/bash -c "${TMP_SCRIPT}" || true
  rm -f "${TMP_SCRIPT}" || true
else
  conda init zsh || true
  conda init bash || true
fi

# Ensure conda bin is on the system PATH for all interactive shells
mkdir -p /etc/profile.d
printf '%s\n' "export PATH=\"${CONDA_DIR}/bin:\$PATH\"" > /etc/profile.d/conda.sh
chmod 644 /etc/profile.d/conda.sh || true

# If a bind-mounted /tmp/environment.yml exists, update base env
if [ -f /tmp/environment.yml ]; then
  echo "python-conda: updating base environment from /tmp/environment.yml"
  mamba env update -n base -f /tmp/environment.yml || true
fi

  chown -R "${NB_UID}":"${NB_GID}" "${CONDA_DIR}" || true

echo "python-conda: done"

# Ensure user caches and local dirs are writable by the notebook user in case
# some installs ran as root earlier in the build.
if [ -d "${HOME_DIR}" ]; then
  chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/.cache" "${HOME_DIR}/.local" "${HOME_DIR}/.ipython" >/dev/null 2>&1 || true
fi
