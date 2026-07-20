# Auto-inserted by scripts/inject_prebaked_helpers.sh
# Source shared feature helpers (prebaked into image) or fall back to repository helper
if [ -n "${FEATURE_HELPERS_DIR:-}" ] && [ -f "${FEATURE_HELPERS_DIR}/helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "${FEATURE_HELPERS_DIR}/helpers.sh"
elif [ -f "../../../scripts/feature_helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "../../../scripts/feature_helpers.sh"
fi
#!/usr/bin/env bash
set -euo pipefail

echo "quarto: meta-feature - all components installed via dependencies"
echo "quarto: - quarto-cli (binary)"
echo "quarto: - quarto-python (kernel integration)"
echo "quarto: - quarto-chromium (rendering)"

# Ensure jupyter-cache is available in the common Python environment (idempotent)
NB_USER=${NB_USER:-jovyan}
HOME_DIR="/home/${NB_USER}"
CONDA_DIR=${CONDA_DIR:-${HOME_DIR}/miniforge3}
echo "quarto: ensuring jupyter-cache is available (meta)"
if [ -x "${CONDA_DIR}/bin/conda" ] || [ -x "${CONDA_DIR}/bin/mamba" ]; then
	if [ -x "${CONDA_DIR}/bin/mamba" ]; then
		"${CONDA_DIR}/bin/mamba" install -y -n base -c conda-forge jupyter-cache || true
	else
		"${CONDA_DIR}/bin/conda" install -y -n base -c conda-forge jupyter-cache || true
	fi
else
	# Fallback: try pip as the notebook user
	TMP_SCRIPT="/tmp/quarto-meta-jcache-install-${NB_USER}.sh"
	cat > "${TMP_SCRIPT}" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
python3 -m pip install --user jupyter-cache || true
BASH
	chmod +x "${TMP_SCRIPT}"
	su - ${NB_USER} -s /bin/bash -c "${TMP_SCRIPT}" || true
	rm -f "${TMP_SCRIPT}"
fi

exit 0
