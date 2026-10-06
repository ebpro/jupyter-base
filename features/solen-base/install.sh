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
HOME_DIR=${HOME_DIR:-/home/${NB_USER}}
CONDA_DIR=${CONDA_DIR:-${HOME_DIR}/miniforge3}

echo "jupyter-base: installing core Jupyter packages into conda base"

# Install core Jupyter packages into base environment
if [ -x "${CONDA_DIR}/bin/mamba" ]; then
  "${CONDA_DIR}/bin/mamba" install -y -n base -c conda-forge \
    jupyter \
    jupyterlab \
    nb_conda_kernels \
    nbgitpuller \
    ipykernel \
    ipython || true
elif [ -x "${CONDA_DIR}/bin/conda" ]; then
  "${CONDA_DIR}/bin/conda" install -y -n base -c conda-forge \
    jupyter \
    jupyterlab \
    nb_conda_kernels \
    nbgitpuller \
    ipykernel \
    ipython || true
else
  echo "jupyter-base: no conda/mamba found, trying pip"
  "${CONDA_DIR}/bin/python" -m pip install \
    jupyter \
    jupyterlab \
    ipykernel \
    ipython || true
fi

# Expose jupyter executables system-wide
for exe in jupyter jupyter-notebook jupyter-lab jupyter-server; do
  if [ -x "${CONDA_DIR}/bin/${exe}" ] && [ ! -e "/usr/local/bin/${exe}" ]; then
    cat > "/usr/local/bin/${exe}" <<EOF
#!/bin/sh
exec "${CONDA_DIR}/bin/${exe}" "\$@"
EOF
    chmod 0755 "/usr/local/bin/${exe}" || true
    chown root:root "/usr/local/bin/${exe}" || true
  fi
done

chown -R "${NB_UID}":"${NB_GID}" "${CONDA_DIR}" || true

echo "jupyter-base: done"
