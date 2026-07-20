# Auto-inserted by scripts/inject_prebaked_helpers.sh
# Source shared feature helpers (prebaked into image) or fall back to repository helper
if [ -n "${FEATURE_HELPERS_DIR:-}" ] && [ -f "${FEATURE_HELPERS_DIR}/helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "${FEATURE_HELPERS_DIR}/helpers.sh"
elif [ -f "../../../scripts/feature_helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "../../../scripts/feature_helpers.sh"
fi
#!/bin/bash
set -e

# Resolve conda path
CONDA_DIR="${CONDA_DIR:-/home/jovyan/miniforge3}"
if [ -f "${CONDA_DIR}/bin/conda" ]; then
    CONDA_BIN="${CONDA_DIR}/bin/conda"
elif [ -f "${CONDA_DIR}/bin/mamba" ]; then
    CONDA_BIN="${CONDA_DIR}/bin/mamba"
else
    echo "⚠️  ml-python-packages: conda not found in ${CONDA_DIR}, skipping"
    exit 0
fi

# Install ML packages via conda
"${CONDA_BIN}" install -y -c conda-forge \
    scikit-learn \
    matplotlib \
    seaborn \
    pandas \
    numpy \
    scipy

echo "ML Python packages installed successfully"
