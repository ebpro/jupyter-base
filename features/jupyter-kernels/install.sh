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

# Ensure IPython dir exists and is writable by the notebook user to avoid
# runtime warnings when kernels are listed from a user-owned environment.
mkdir -p "${HOME_DIR}/.ipython" >/dev/null 2>&1 || true
chown -R ${NB_UID:-1001}:${NB_GID:-1001} "${HOME_DIR}/.ipython" >/dev/null 2>&1 || true

echo "jupyter-kernels: installing zsh_jupyter_kernel and bash_kernel if available"
CONDA_DIR=${CONDA_DIR:-${HOME_DIR}/miniforge3}
PYTHON_EXEC=${CONDA_DIR}/bin/python

install_pkg_if_missing() {
  local pkg="$1" install_name="$2"
  local py="${PYTHON_EXEC}"
  if [ ! -x "$py" ]; then
    py="$(command -v python3 || true)"
  fi
  if [ -z "$py" ]; then
    echo "jupyter-kernels: no python interpreter found to check/install $pkg" >&2
    return 1
  fi

  if "$py" -c "import importlib,sys; print(importlib.util.find_spec('$pkg') is not None)" 2>/dev/null | grep -q True; then
    echo "jupyter-kernels: $pkg already available in interpreter"
  else
    echo "jupyter-kernels: installing $pkg into conda base environment"
    if [ -x "${CONDA_DIR}/bin/mamba" ]; then
      "${CONDA_DIR}/bin/mamba" install -y -n base -c conda-forge "$install_name" || true
    elif [ -x "${CONDA_DIR}/bin/conda" ]; then
      "${CONDA_DIR}/bin/conda" install -y -n base -c conda-forge "$install_name" || true
    else
      # fallback to pip using conda python if available; if not, run pip as the notebook user
      if [ -x "${CONDA_DIR}/bin/python" ]; then
        "${CONDA_DIR}/bin/python" -m pip install "$install_name" || true
      else
        su - ${NB_USER:-jovyan} -s /bin/bash -c "python3 -m pip install '$install_name'" || true
      fi
    fi

    # If conda/mamba ran but package still not importable, try pip as fallback
    if ! "$py" -c "import importlib; print(importlib.util.find_spec('$pkg') is not None)" 2>/dev/null | grep -q True; then
      echo "jupyter-kernels: package $install_name not available after conda install; trying pip fallback"
      if [ -x "${CONDA_DIR}/bin/python" ]; then
        "${CONDA_DIR}/bin/python" -m pip install "$install_name" || true
      else
        su - ${NB_USER:-jovyan} -s /bin/bash -c "python3 -m pip install '$install_name'" || true
      fi
      # ensure caches and local dirs are owned by the notebook user after pip fallback
      chown -R ${NB_UID:-1001}:${NB_GID:-1001} "${HOME_DIR}/.cache" "${HOME_DIR}/.local" "${HOME_DIR}/.ipython" >/dev/null 2>&1 || true
    fi
  fi

  # Attempt to register the kernel using the interpreter that owns the package
  module_name="${pkg}"
  if [ -x "${CONDA_DIR}/bin/python" ]; then
    "${CONDA_DIR}/bin/python" -m "${module_name}.install" --sys-prefix || true
  elif command -v python3 >/dev/null 2>&1; then
    su - ${NB_USER:-jovyan} -s /bin/bash -c "python3 -m '${module_name}.install' --sys-prefix" || true
  fi
  # ensure the user dirs are owned correctly after registration
  chown -R ${NB_UID:-1001}:${NB_GID:-1001} "${HOME_DIR}/.cache" "${HOME_DIR}/.local" "${HOME_DIR}/.ipython" >/dev/null 2>&1 || true
}

INSTALL_ZSH_KERNEL=${INSTALL_ZSH_KERNEL:-${1:-${install_zsh_kernel:-true}}}
INSTALL_BASH_KERNEL=${INSTALL_BASH_KERNEL:-${2:-${install_bash_kernel:-true}}}

# zsh_jupyter_kernel: package name on PyPI is 'zsh-jupyter-kernel' but module is 'zsh_jupyter_kernel'
if [ "${INSTALL_ZSH_KERNEL}" = "true" ]; then
  install_pkg_if_missing "zsh_jupyter_kernel" "zsh-jupyter-kernel"
else
  echo "jupyter-kernels: INSTALL_ZSH_KERNEL is false; skipping zsh kernel"
fi

# bash_kernel package name matches module
if [ "${INSTALL_BASH_KERNEL}" = "true" ]; then
  install_pkg_if_missing "bash_kernel" "bash_kernel"
else
  echo "jupyter-kernels: INSTALL_BASH_KERNEL is false; skipping bash kernel"
fi

echo "jupyter-kernels: done"
