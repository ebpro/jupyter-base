#!/usr/bin/env bash
set -euo pipefail

NB_USER=${NB_USER:-jovyan}
NB_UID=${NB_UID:-1001}
NB_GID=${NB_GID:-1001}
HOME_DIR="/home/${NB_USER}"

echo "quarto-python: configuring Python kernel for Quarto"

if ! command -v python3 >/dev/null 2>&1; then
  echo "quarto-python: python3 not found, skipping" >&2
  exit 0
fi

# Ensure ipykernel is installed
echo "quarto-python: ensuring ipykernel is available"
if python3 -c "import importlib; print(importlib.util.find_spec('ipykernel') is not None)" 2>/dev/null | grep -q True; then
  echo "quarto-python: ipykernel already installed"
else
  echo "quarto-python: installing ipykernel via conda/mamba"
  if [ -x "${HOME_DIR}/miniforge3/bin/mamba" ]; then
    "${HOME_DIR}/miniforge3/bin/mamba" install -y -n base -c conda-forge ipykernel notebook PyYAML || true
  elif [ -x "${HOME_DIR}/miniforge3/bin/conda" ]; then
    "${HOME_DIR}/miniforge3/bin/conda" install -y -n base -c conda-forge ipykernel notebook PyYAML || true
  else
    # Fallback to pip
    mkdir -p "${HOME_DIR}/.cache/pip"
    chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/.cache/pip"
    TMP_SCRIPT="/tmp/quarto-pip-install-${NB_USER}.sh"
    cat > "${TMP_SCRIPT}" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
source "$HOME/miniforge3/etc/profile.d/conda.sh" 2>/dev/null || true
export PATH="$HOME/miniforge3/bin:$PATH"
python3 -m pip install --upgrade --user pip setuptools wheel --no-cache-dir || true
python3 -m pip install --upgrade --user ipykernel notebook PyYAML --no-cache-dir || true
BASH
    chmod +x "${TMP_SCRIPT}"
    su - ${NB_USER} -s /bin/bash -c "${TMP_SCRIPT}" || true
    rm -f "${TMP_SCRIPT}"
  fi
fi

# Register kernel for Quarto
TMP_SCRIPT="/tmp/quarto-kernel-install-${NB_USER}.sh"
cat > "${TMP_SCRIPT}" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
source "$HOME/miniforge3/etc/profile.d/conda.sh" 2>/dev/null || true
export PATH="$HOME/miniforge3/bin:$PATH"
python3 -m ipykernel install --sys-prefix --name "python3-quarto" --display-name "Python 3 (Quarto)" || true
BASH
chmod +x "${TMP_SCRIPT}"
su - ${NB_USER} -s /bin/bash -c "${TMP_SCRIPT}" 2>/dev/null || true
rm -f "${TMP_SCRIPT}"

# Create system kernelspec pointing to Miniforge python
if [ -x "${HOME_DIR}/miniforge3/bin/python" ]; then
  KERNEL_DIR="/usr/local/share/jupyter/kernels/python3-quarto"
  mkdir -p "${KERNEL_DIR}"
  cat > "${KERNEL_DIR}/kernel.json" <<EOF
{
  "argv": ["${HOME_DIR}/miniforge3/bin/python", "-m", "ipykernel_launcher", "-f", "{connection_file}"],
  "display_name": "Python 3 (Quarto - Miniforge)",
  "language": "python"
}
EOF
  chmod -R 755 "${KERNEL_DIR}"
  chown -R root:root "${KERNEL_DIR}"
fi

[ -d "${HOME_DIR}/.local" ] && chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/.local" || true

echo "quarto-python: configuration complete"
