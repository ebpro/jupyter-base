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

NB_USER=${NB_USER:-jovyan}
NB_UID=${NB_UID:-1001}
NB_GID=${NB_GID:-1001}
HOME_DIR="/home/${NB_USER}"
CONDA_DIR="${CONDA_DIR:-${HOME_DIR}/miniforge3}"

# Ensure common user directories exist
if command -v fh_ensure_user_dirs >/dev/null 2>&1; then
  fh_ensure_user_dirs "${NB_USER}" "${NB_UID}" "${NB_GID}" || true
else
  mkdir -p "${HOME_DIR}/.local/bin" "${HOME_DIR}/.cache" || true
  chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/.local" "${HOME_DIR}/.cache" || true
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

echo "quarto-cli: starting installation"

# Resolve version
resolve_version() {
  local tool="$1" v=""
  read_tool_from_json() {
    local file="$1"; local t="$2"
    if [ ! -f "$file" ]; then echo ""; return 0; fi
    if command -v jq >/dev/null 2>&1; then
      jq -r --arg t "$t" '.tools[$t] // empty' "$file" 2>/dev/null || true
      return 0
    fi
    grep -E "\"$t\"[[:space:]]*:[[:space:]]*\"[^\"]+\"" "$file" 2>/dev/null | sed -E 's/.*:[[:space:]]*"(.*)".*/\1/' | head -n1 || true
  }
  if [ -f "${PWD}/artefacts/${tool}/versions.json" ]; then
    v=$(read_tool_from_json "${PWD}/artefacts/${tool}/versions.json" "$tool")
    [ -n "$v" ] && { echo "$v"; return 0; }
  fi
  if [ -f "${SCRIPT_DIR}/../../artefacts/${tool}/versions.json" ]; then
    v=$(read_tool_from_json "${SCRIPT_DIR}/../../artefacts/${tool}/versions.json" "$tool")
    [ -n "$v" ] && { echo "$v"; return 0; }
  fi
  # prefer centralized resolver
  if command -v fh_resolve_version >/dev/null 2>&1; then
    v=$(fh_resolve_version "$tool" || true)
    [ -n "$v" ] && { echo "$v"; return 0; }
  fi
  if [ -f "${PWD}/Artefacts/versions.json" ]; then
    v=$(read_tool_from_json "${PWD}/Artefacts/versions.json" "$tool")
    [ -n "$v" ] && { echo "$v"; return 0; }
  fi
  if [ -f "${SCRIPT_DIR}/../../Artefacts/versions.json" ]; then
    v=$(read_tool_from_json "${SCRIPT_DIR}/../../Artefacts/versions.json" "$tool")
    [ -n "$v" ] && { echo "$v"; return 0; }
  fi
  if [ -f /tmp/versions.json ]; then
    v=$(jq -r --arg t "$tool" '.tools[$t] // empty' /tmp/versions.json 2>/dev/null || true)
    [ -n "$v" ] && { echo "$v"; return 0; }
  fi
  echo ""
}

QUARTO_VERSION="${QUARTO_VERSION:-$(resolve_version "quarto")}"
if [ -z "${QUARTO_VERSION}" ]; then
  echo "quarto-cli: version not found, skipping" >&2
  exit 0
fi

echo "quarto-cli: installing Quarto CLI ${QUARTO_VERSION}"

# Normalize architecture
if [ -f "${PWD}/scripts/arch.sh" ]; then
  source "${PWD}/scripts/arch.sh"
  ARCH=$(arch_map "${TARGETPLATFORM:-$(uname -m)}")
else
  ARCH=$(case "$(uname -m)" in x86_64|X86_64) echo "amd64" ;; aarch64|arm64) echo "arm64" ;; *) echo "amd64" ;; esac)
fi

# Download and extract Quarto using shared helper
mkdir -p /opt/quarto
# Build explicit filename to avoid placeholder/template issues during build
# Strip leading 'v' from version when constructing filenames (helper will add the 'v' tag)
QUARTO_VER_NOV=${QUARTO_VERSION#v}
FNAME="quarto-${QUARTO_VER_NOV}-linux-${ARCH}.tar.gz"
download_github_release \
  "quarto-dev/quarto-cli" \
  "quarto" \
  "${QUARTO_VER_NOV}" \
  "/opt/quarto" \
  "${FNAME}" \
  "true"

## Determine runtime location and create wrappers that point to the real executable
INSTDIR=""
extracted_dir=$(find /opt/quarto -maxdepth 1 -type d -name "quarto*" -print -quit || true)

# Prefer extracted_dir/bin/quarto
if [ -n "$extracted_dir" ] && [ -x "${extracted_dir}/bin/quarto" ]; then
  INSTDIR="$extracted_dir"
fi

# If not found, accept a top-level binary or /opt/quarto/bin/quarto
if [ -z "$INSTDIR" ]; then
  if [ -x "/opt/quarto/quarto" ]; then
    INSTDIR="/opt/quarto"
  elif [ -x "/opt/quarto/bin/quarto" ]; then
    INSTDIR="/opt/quarto"
  else
    # Try to find any quarto binary under /opt/quarto and derive INSTDIR
    maybe_bin=$(find /opt/quarto -type f -name 'quarto' -print -quit || true)
    if [ -n "$maybe_bin" ] && [ -f "$maybe_bin" ]; then
      if [ -x "$maybe_bin" ]; then
        # If it's under .../bin/quarto set INSTDIR to parent dir
        parent_dir=$(dirname "$(dirname "$maybe_bin")")
        INSTDIR="$parent_dir"
      else
        # make it executable and set INSTDIR to its parent dir
        chmod +x "$maybe_bin" 2>/dev/null || true
        parent_dir=$(dirname "$(dirname "$maybe_bin")")
        INSTDIR="$parent_dir"
      fi
    fi
  fi
fi

# Final verification: prefer ${INSTDIR}/bin/quarto, fallback to ${INSTDIR}/quarto
if [ -n "$INSTDIR" ]; then
  if [ -x "${INSTDIR}/bin/quarto" ]; then
    QUARTO_EXE="${INSTDIR}/bin/quarto"
  elif [ -x "${INSTDIR}/quarto" ]; then
    QUARTO_EXE="${INSTDIR}/quarto"
  else
    QUARTO_EXE=""
  fi
fi

if [ -z "$QUARTO_EXE" ] || [ ! -x "$QUARTO_EXE" ]; then
  echo "quarto-cli: installation failed - quarto binary not found" >&2
  exit 1
fi

echo "quarto-cli: found runtime at ${INSTDIR} -> ${QUARTO_EXE}"

# Create wrapper in /usr/local/bin
mkdir -p /usr/local/bin
cat > /usr/local/bin/quarto <<WRAPPER
#!/bin/sh
export PATH="${CONDA_DIR}/bin:$(dirname "$QUARTO_EXE"):\$PATH"
export QUARTO_PYTHON="${CONDA_DIR}/bin/python3"
exec "$QUARTO_EXE" "\$@"
WRAPPER
chmod 0755 /usr/local/bin/quarto
chown root:root /usr/local/bin/quarto

# Add to system PATH via profile.d
mkdir -p /etc/profile.d
cat > /etc/profile.d/quarto.sh <<PROFILE
export PATH="${CONDA_DIR}/bin:$(dirname "$QUARTO_EXE"):\$PATH"
export QUARTO_PYTHON="${CONDA_DIR}/bin/python3"
PROFILE
chmod 644 /etc/profile.d/quarto.sh

# Create per-user shim
if [ -d "${HOME_DIR}" ]; then
  TMP_SCRIPT="/tmp/quarto-user-setup-${NB_USER}.sh"
  cat > "${TMP_SCRIPT}" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p ~/.local/bin 2>/dev/null || true
BASH
  echo "ln -sf \"$QUARTO_EXE\" ~/.local/bin/quarto || true" >> "${TMP_SCRIPT}"
  cat >> "${TMP_SCRIPT}" <<'BASH'
if [ -f ~/.zshrc ]; then
  grep -qxF 'export PATH="$HOME/.local/bin:$PATH"' ~/.zshrc 2>/dev/null || \
    echo 'export PATH="$HOME/.local/bin:${PATH}"' >> ~/.zshrc
else
  echo 'export PATH="$HOME/.local/bin:${PATH}"' >> ~/.zshrc
fi
BASH
  chmod +x "${TMP_SCRIPT}"
  su - ${NB_USER} -s /bin/bash -c "${TMP_SCRIPT}" || true
  rm -f "${TMP_SCRIPT}"
  [ -d "${HOME_DIR}/.local" ] && chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/.local" || true
fi

# Ensure jupyter-cache available for users invoking Quarto CLI (idempotent)
echo "quarto-cli: ensuring jupyter-cache is available"
if [ -x "${CONDA_DIR}/bin/mamba" ]; then
  "${CONDA_DIR}/bin/mamba" install -y -n base -c conda-forge jupyter-cache || true
elif [ -x "${CONDA_DIR}/bin/conda" ]; then
  "${CONDA_DIR}/bin/conda" install -y -n base -c conda-forge jupyter-cache || true
else
  TMP_SCRIPT="/tmp/quarto-cli-jcache-${NB_USER}.sh"
  cat > "${TMP_SCRIPT}" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
python3 -m pip install --user jupyter-cache || true
BASH
  chmod +x "${TMP_SCRIPT}"
  su - ${NB_USER} -s /bin/bash -c "${TMP_SCRIPT}" || true
  rm -f "${TMP_SCRIPT}"
fi

echo "quarto-cli: installation complete"
