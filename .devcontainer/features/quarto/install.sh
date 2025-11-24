#!/usr/bin/env bash
set -euo pipefail

NB_USER=${NB_USER:-jovyan}
NB_UID=${NB_UID:-1001}
NB_GID=${NB_GID:-1001}
HOME_DIR="/home/${NB_USER}"

QUARTO_VERSION=""
# Resolve version: prefer per-feature artefacts, then central artefacts, then /tmp (CI-mounted)
resolve_version() {
  local tool="$1"
  local v=""
  # 1) per-feature file in workspace
  if [ -f "${PWD}/Artefacts/features/${tool}/versions.json" ]; then
    v=$(jq -r --arg t "$tool" '.tools[$t] // empty' "${PWD}/Artefacts/features/${tool}/versions.json" 2>/dev/null || true)
    [ -n "$v" ] && { echo "$v"; return 0; }
  fi
  # 2) central workspace Artefacts
  if [ -f "${PWD}/Artefacts/versions.json" ]; then
    v=$(jq -r --arg t "$tool" '.tools[$t] // empty' "${PWD}/Artefacts/versions.json" 2>/dev/null || true)
    [ -n "$v" ] && { echo "$v"; return 0; }
  fi
  # 3) CI-mounted /tmp/versions.json
  if [ -f /tmp/versions.json ]; then
    v=$(jq -r --arg t "$tool" '.tools[$t] // empty' /tmp/versions.json 2>/dev/null || true)
    [ -n "$v" ] && { echo "$v"; return 0; }
  fi
  echo ""
}

QUARTO_VERSION=$(resolve_version "quarto" )
if [ -z "${QUARTO_VERSION}" ]; then
  echo "quarto: version not found in Artefacts or /tmp/versions.json, skipping" >&2
  exit 0
fi

echo "quarto: installing Quarto ${QUARTO_VERSION}"
# Normalize architecture when possible
if [ -f "${PWD}/scripts/arch.sh" ]; then
  # shellcheck source=/dev/null
  source "${PWD}/scripts/arch.sh"
  ARCH=$(arch_map "${TARGETPLATFORM:-$(uname -m)}")
else
  ARCH=$(case "$(uname -m)" in x86_64) echo "amd64" ;; X86_64) echo "amd64" ;; aarch64) echo "arm64" ;; arm64) echo "arm64" ;; *) echo "amd64" ;; esac)
fi

# Use toolcache-get to install Quarto into /opt/toolcache to avoid duplication across profiles
QUARTO_URL="https://github.com/quarto-dev/quarto-cli/releases/download/v${QUARTO_VERSION}/quarto-${QUARTO_VERSION}-linux-${ARCH}.tar.gz"
QUARTO_CHKSUM=""
# Resolve checksum: per-feature checksums -> central Artefacts -> /tmp
resolve_checksum() {
  local tool="$1"; local ver="$2"; local arch="$3"; local cs=""
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

QUARTO_CHKSUM=$(resolve_checksum "quarto" "${QUARTO_VERSION}" "${ARCH}")

if command -v toolcache-get >/dev/null 2>&1; then
  TOOLCACHE=toolcache-get
else
  TOOLCACHE="/usr/local/bin/toolcache-get"
fi

PREFIX=$($TOOLCACHE "quarto" "${QUARTO_VERSION}" "${QUARTO_URL}" "${QUARTO_CHKSUM}" "quarto-${QUARTO_VERSION}/bin/quarto" || true)
if [ -n "$PREFIX" ]; then
  mkdir -p "${HOME_DIR}/.local/bin"
  if [ -x "$PREFIX/bin/quarto" ]; then
    ln -sf "$PREFIX/bin/quarto" "${HOME_DIR}/.local/bin/quarto"
  else
    # try to find the quarto binary
    found=$(find "$PREFIX" -type f -name quarto -perm /111 -print -quit 2>/dev/null || true)
    if [ -n "$found" ]; then
      ln -sf "$found" "${HOME_DIR}/.local/bin/quarto"
    fi
  fi
  echo 'export PATH="${HOME}/.local/bin:${PATH}"' >> "${HOME_DIR}/.zshrc"
fi

# Optionally install Chromium if requested via env INSTALL_CHROMIUM=1 (feature.json default false)
if [ "${DEVCONTAINER_QUARTO_INSTALL_CHROMIUM:-false}" = "true" ] || [ "${DEVCONTAINER_quarto_install_chromium:-false}" = "true" ]; then
  echo "quarto: installing Chromium runtime (this increases image size)"
  su - ${NB_USER} -c "${HOME_DIR}/.local/bin/quarto install chromium --no-prompt" || true
fi

chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/opt/quarto-${QUARTO_VERSION}" || true
chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/.local/bin" || true
echo "quarto: done"

# Ensure a Python kernel is available for Quarto execution (idempotent)
if command -v python3 >/dev/null 2>&1; then
  echo "quarto: ensuring Python kernel (ipykernel) is installed and registered"
  if python3 -c "import importlib, sys; print(importlib.util.find_spec('ipykernel') is not None)" 2>/dev/null | grep -q True; then
    echo "quarto: ipykernel already available"
  else
    echo "quarto: installing ipykernel via pip as ${NB_USER}"
    # Ensure pip cache dir exists and is owned by the non-root user
    mkdir -p "${HOME_DIR}/.cache/pip"
    chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/.cache/pip"
    # Run pip as the non-root user to avoid root-run warnings and permission issues
    # Ensure Miniforge python is on PATH for the non-root user before running pip
    su - ${NB_USER} -c "bash -lc 'source ${HOME_DIR}/miniforge3/etc/profile.d/conda.sh >/dev/null 2>&1 || true; export PATH=\"${HOME_DIR}/miniforge3/bin:\$PATH\"; python3 -m pip install --upgrade pip setuptools wheel --no-cache-dir'" >/dev/null || true
    su - ${NB_USER} -c "bash -lc 'source ${HOME_DIR}/miniforge3/etc/profile.d/conda.sh >/dev/null 2>&1 || true; export PATH=\"${HOME_DIR}/miniforge3/bin:\$PATH\"; python3 -m pip install --upgrade ipykernel --no-cache-dir'" >/dev/null || true
  fi
  # register a sys-prefix kernel so Quarto can find it when running as non-root user
  su - ${NB_USER} -c "bash -lc 'source ${HOME_DIR}/miniforge3/etc/profile.d/conda.sh >/dev/null 2>&1 || true; export PATH=\"${HOME_DIR}/miniforge3/bin:\$PATH\"; python3 -m ipykernel install --sys-prefix --name \"python3-quarto\" --display-name \"Python 3 (Quarto)\"'" >/dev/null 2>&1 || true
else
  echo "quarto: python3 not found; skipping ipykernel registration"
fi

# Optionally install and register zsh kernel for executable zsh cells in Quarto
if [ "${DEVCONTAINER_QUARTO_INSTALL_ZSH_KERNEL:-false}" = "true" ]; then
  echo "quarto: ensuring zsh Jupyter kernel is available"
  if python3 -c "import importlib, sys; print(importlib.util.find_spec('zsh_jupyter_kernel') is not None)" 2>/dev/null | grep -q True; then
    echo "quarto: zsh_jupyter_kernel already installed"
  else
    echo "quarto: installing zsh_jupyter_kernel via pip as ${NB_USER}"
    mkdir -p "${HOME_DIR}/.cache/pip"
    chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/.cache/pip"
    su - ${NB_USER} -c "bash -lc 'source ${HOME_DIR}/miniforge3/etc/profile.d/conda.sh >/dev/null 2>&1 || true; export PATH=\"${HOME_DIR}/miniforge3/bin:\$PATH\"; python3 -m pip install --no-cache-dir zsh-jupyter-kernel'" >/dev/null 2>&1 || \
      su - ${NB_USER} -c "bash -lc 'source ${HOME_DIR}/miniforge3/etc/profile.d/conda.sh >/dev/null 2>&1 || true; export PATH=\"${HOME_DIR}/miniforge3/bin:\$PATH\"; python3 -m pip install --no-cache-dir zsh_jupyter_kernel'" >/dev/null 2>&1 || true
  fi
  su - ${NB_USER} -c "bash -lc 'source ${HOME_DIR}/miniforge3/etc/profile.d/conda.sh >/dev/null 2>&1 || true; export PATH=\"${HOME_DIR}/miniforge3/bin:\$PATH\"; python3 -m zsh_jupyter_kernel.install --sys-prefix'" >/dev/null 2>&1 || true
fi

chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/.local" || true
