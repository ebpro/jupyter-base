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

NB_USER=${NB_USER:-jovyan}
NB_UID=${NB_UID:-1001}
NB_GID=${NB_GID:-1001}
HOME_DIR="/home/${NB_USER}"

# Directory containing this script (helps when feature runs with different PWD)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"


echo "-----> quarto: starting installation script ---"

QUARTO_VERSION=""
# Resolve version: prefer per-feature artefacts, then central artefacts, then /tmp (CI-mounted)
resolve_version() {
  local tool="$1"
  local v=""
  # Helper: read tool value from a small JSON file without jq if needed
  read_tool_from_json() {
    local file="$1"; local t="$2"; local out=""
    if [ ! -f "$file" ]; then
      echo ""; return 0
    fi
    if command -v jq >/dev/null 2>&1; then
      jq -r --arg t "$t" '.tools[$t] // empty' "$file" 2>/dev/null || true
      return 0
    fi
    out=$(grep -E "\"$t\"[[:space:]]*:[[:space:]]*\"[^\"]+\"" "$file" 2>/dev/null | sed -E 's/.*:[[:space:]]*"(.*)".*/\1/' | head -n1 || true)
    echo "$out"
  }
  # 1) per-feature file in workspace
  if [ -f "${PWD}/Artefacts/features/${tool}/versions.json" ]; then
    v=$(read_tool_from_json "${PWD}/Artefacts/features/${tool}/versions.json" "$tool" 2>/dev/null || true)
    [ -n "$v" ] && { echo "$v"; return 0; }
  fi
  # 1b) per-feature file relative to this script (useful when executed from feature dir)
  # When running inside the build step features are copied to /tmp/features/<name>
  # and Artefacts is mounted at /tmp/Artefacts. Use ../../ to reach /tmp/Artefacts.
  if [ -f "${SCRIPT_DIR}/../../Artefacts/features/${tool}/versions.json" ]; then
    v=$(read_tool_from_json "${SCRIPT_DIR}/../../Artefacts/features/${tool}/versions.json" "$tool" 2>/dev/null || true)
    [ -n "$v" ] && { echo "$v"; return 0; }
  fi
  # 2) central workspace Artefacts
  if [ -f "${PWD}/Artefacts/versions.json" ]; then
    v=$(read_tool_from_json "${PWD}/Artefacts/versions.json" "$tool" 2>/dev/null || true)
    [ -n "$v" ] && { echo "$v"; return 0; }
  fi
  # 2b) central Artefacts relative to this script
  if [ -f "${SCRIPT_DIR}/../../Artefacts/versions.json" ]; then
    v=$(read_tool_from_json "${SCRIPT_DIR}/../../Artefacts/versions.json" "$tool" 2>/dev/null || true)
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
  # feature-relative checksums (script location)
  if [ -f "${SCRIPT_DIR}/../../Artefacts/features/${tool}/checksums.json" ]; then
    cs=$(jq -r --arg t "$tool" --arg v "$ver" --arg a "$arch" '.tools[$t].checksums[$v][$a] // empty' "${SCRIPT_DIR}/../../Artefacts/features/${tool}/checksums.json" 2>/dev/null || true)
    [ -n "$cs" ] && { echo "$cs"; return 0; }
  fi
  if [ -f "${PWD}/Artefacts/checksums.json" ]; then
    cs=$(jq -r --arg t "$tool" --arg v "$ver" --arg a "$arch" '.tools[$t].checksums[$v][$a] // empty' "${PWD}/Artefacts/checksums.json" 2>/dev/null || true)
    [ -n "$cs" ] && { echo "$cs"; return 0; }
  fi
  # central checksums relative to script
  if [ -f "${SCRIPT_DIR}/../../Artefacts/checksums.json" ]; then
    cs=$(jq -r --arg t "$tool" --arg v "$ver" --arg a "$arch" '.tools[$t].checksums[$v][$a] // empty' "${SCRIPT_DIR}/../../Artefacts/checksums.json" 2>/dev/null || true)
    [ -n "$cs" ] && { echo "$cs"; return 0; }
  fi
  if [ -f /tmp/checksums.json ]; then
    cs=$(jq -r --arg t "$tool" --arg v "$ver" --arg a "$arch" '.tools[$t].checksums[$v][$a] // empty' /tmp/checksums.json 2>/dev/null || true)
    [ -n "$cs" ] && { echo "$cs"; return 0; }
  fi
  echo ""
}

QUARTO_CHKSUM=$(resolve_checksum "quarto" "${QUARTO_VERSION}" "${ARCH}")

## Use cached tarball installation for reliability and repeatable runtime layout.
# Cache tarball under /opt/toolcache/quarto and extract to /opt/quarto/quarto-<ver>
CACHE_DIR=/opt/toolcache/quarto
CACHE_TGZ="$CACHE_DIR/quarto-${QUARTO_VERSION}.tar.gz"
RUNTIME_DIR=/opt/quarto/quarto-${QUARTO_VERSION}

mkdir -p "$CACHE_DIR" /opt/quarto

# Download tarball into cache if missing
if [ ! -f "$CACHE_TGZ" ]; then
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$QUARTO_URL" -o "$CACHE_TGZ" || true
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$CACHE_TGZ" "$QUARTO_URL" || true
  fi
fi

# Verify checksum when provided
if [ -n "${QUARTO_CHKSUM:-}" ] && [ -f "$CACHE_TGZ" ] && command -v sha256sum >/dev/null 2>&1; then
  echo "${QUARTO_CHKSUM}  $CACHE_TGZ" | sha256sum -c - >/dev/null 2>&1 || (
    echo "quarto: checksum verification failed for $CACHE_TGZ" >&2; rm -f "$CACHE_TGZ"; true)
fi

# Extract into runtime dir (remove any previous extract for idempotence)
rm -rf "$RUNTIME_DIR"
if [ -f "$CACHE_TGZ" ]; then
  tar -xzf "$CACHE_TGZ" -C /opt/quarto || true
fi

# Determine a usable installation directory by checking several likely locations
INSTDIR=""
# 1) directory created by tar extraction (e.g. /opt/quarto/quarto-1.8.24)
extracted_dir=$(find /opt/quarto -maxdepth 1 -type d -name "quarto*" -print -quit || true)
if [ -n "$extracted_dir" ] && [ -x "${extracted_dir}/bin/quarto" ]; then
  INSTDIR="$extracted_dir"
fi
# 2) explicit runtime dir path
if [ -z "$INSTDIR" ] && [ -x "${RUNTIME_DIR}/bin/quarto" ]; then
  INSTDIR="$RUNTIME_DIR"
fi
# 3) toolcache layout (fallback)
if [ -z "$INSTDIR" ]; then
  if [ -x "/opt/toolcache/quarto/${QUARTO_VERSION}/bin/quarto" ]; then
    INSTDIR="/opt/toolcache/quarto/${QUARTO_VERSION}"
  fi
fi

# If we have a usable INSTDIR with a quarto binary, create wrapper and profile
if [ -n "${INSTDIR}" ] && [ -x "${INSTDIR}/bin/quarto" ]; then
  echo "quarto: found runtime at ${INSTDIR} — creating wrapper/profile"
  # create stable wrapper in /usr/local/bin (always present for all users)
  mkdir -p /usr/local/bin
  cat > /usr/local/bin/quarto <<EOF
#!/bin/sh
exec "${INSTDIR}/bin/quarto" "\$@"
EOF
  chmod 0755 /usr/local/bin/quarto || true
  chown root:root /usr/local/bin/quarto || true

  # add to system PATH via profile.d (helps login and non-login interactive shells)
  mkdir -p /etc/profile.d
  printf '%s\n' "export PATH=\"${INSTDIR}/bin:\$PATH\"" > /etc/profile.d/quarto.sh
  chmod 644 /etc/profile.d/quarto.sh || true

  # create per-user shim only if the home dir exists
  if [ -d "${HOME_DIR}" ]; then
    su - ${NB_USER} -c "bash -lc 'mkdir -p ~/.local/bin >/dev/null 2>&1 || true; ln -sf \"${INSTDIR}/bin/quarto\" ~/.local/bin/quarto'" || true
    # ensure ownership of user local dir and add zshrc PATH entry
    if [ -d "${HOME_DIR}/.local" ]; then
      chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/.local" || true
    fi
    if [ -f "${HOME_DIR}/.zshrc" ]; then
      grep -qxF "export PATH=\"${HOME_DIR}/.local/bin:\$PATH\"" "${HOME_DIR}/.zshrc" 2>/dev/null || \
        echo "export PATH=\"${HOME_DIR}/.local/bin:\${PATH}\"" >> "${HOME_DIR}/.zshrc"
    else
      echo "export PATH=\"${HOME_DIR}/.local/bin:\${PATH}\"" >> "${HOME_DIR}/.zshrc"
      chown ${NB_UID}:${NB_GID} "${HOME_DIR}/.zshrc" || true
    fi
  fi
fi

# Optionally install Chromium if requested via env INSTALL_CHROMIUM=1 (feature.json default false)
if [ "${DEVCONTAINER_QUARTO_INSTALL_CHROMIUM:-false}" = "true" ] || [ "${DEVCONTAINER_quarto_install_chromium:-false}" = "true" ]; then
  echo "quarto: installing Chromium runtime (this increases image size)"
  su - ${NB_USER} -c "${HOME_DIR}/.local/bin/quarto install chromium --no-prompt" || true
fi

if [ -d "${HOME_DIR}/opt/quarto-${QUARTO_VERSION}" ]; then
  chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/opt/quarto-${QUARTO_VERSION}" || true
fi
if [ -d "${HOME_DIR}/.local/bin" ]; then
  chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/.local/bin" || true
fi
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

if [ -d "${HOME_DIR}/.local" ]; then
  chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/.local" || true
fi
