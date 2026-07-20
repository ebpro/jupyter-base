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

NB_USER=${NB_USER:-jovyan}
NB_UID=${NB_UID:-1001}
NB_GID=${NB_GID:-1001}
HOME_DIR="/home/${NB_USER}"

echo "quarto-chromium: installing Chromium runtime"

TMP_SCRIPT="/tmp/quarto-chromium-install-${NB_USER}.sh"
cat > "${TMP_SCRIPT}" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$HOME/.local/bin" 2>/dev/null || true
"$HOME/.local/bin/quarto" install chromium --no-prompt || true
BASH

chmod +x "${TMP_SCRIPT}"
su - ${NB_USER} -s /bin/bash -c "${TMP_SCRIPT}" || true
rm -f "${TMP_SCRIPT}"

echo "quarto-chromium: installation complete"

# Ensure jupyter-cache available for Quarto rendering tasks (if Python present)
CONDA_DIR=${CONDA_DIR:-${HOME_DIR}/miniforge3}
echo "quarto-chromium: ensuring jupyter-cache is available"
if [ -x "${CONDA_DIR}/bin/mamba" ]; then
	"${CONDA_DIR}/bin/mamba" install -y -n base -c conda-forge jupyter-cache || true
elif [ -x "${CONDA_DIR}/bin/conda" ]; then
	"${CONDA_DIR}/bin/conda" install -y -n base -c conda-forge jupyter-cache || true
else
	TMP_SCRIPT="/tmp/quarto-chromium-jcache-${NB_USER}.sh"
	cat > "${TMP_SCRIPT}" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
python3 -m pip install --user jupyter-cache || true
BASH
	chmod +x "${TMP_SCRIPT}"
	su - ${NB_USER} -s /bin/bash -c "${TMP_SCRIPT}" || true
	rm -f "${TMP_SCRIPT}"
fi
