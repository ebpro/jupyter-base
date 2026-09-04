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

# Use the available Quarto binary (search PATH or common /opt/quarto/* location)
TMP_SCRIPT="/tmp/quarto-chromium-install-${NB_USER}.sh"
cat > "${TMP_SCRIPT}" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
# locate quarto binary, prefer PATH, then common install locations
QUARTO_BIN=$(command -v quarto || true)
if [ -z "${QUARTO_BIN}" ]; then
  for c in "$HOME/.local/bin/quarto" "$HOME/miniforge3/bin/quarto" /usr/local/bin/quarto /opt/quarto/*/bin/quarto; do
    if [ -x "$c" ]; then
      QUARTO_BIN="$c"
      break
    fi
  done
fi
if [ -n "${QUARTO_BIN}" ] && [ -x "${QUARTO_BIN}" ]; then
  CI=true "${QUARTO_BIN}" install chromium --no-prompt || CI=true "${QUARTO_BIN}" install chromium || true
else
  echo "quarto binary not found; skipping 'quarto install chromium'" >&2
fi
BASH

chmod +x "${TMP_SCRIPT}"
su - ${NB_USER} -s /bin/bash -c "${TMP_SCRIPT}" || true
rm -f "${TMP_SCRIPT}"

CHROMIUM_BIN=""
for c in "${HOME_DIR}/.quarto/bin/chromium" "${HOME_DIR}/.quarto/bin/chromium-browser" /usr/bin/chromium /usr/bin/chromium-browser; do
  if [ -x "$c" ]; then
    CHROMIUM_BIN="$c"
    break
  fi
done
if [ -z "${CHROMIUM_BIN}" ]; then
  CHROMIUM_BIN=$(find "${HOME_DIR}/.quarto" -type f \( -name chromium -o -name chromium-browser -o -name chrome \) -perm -111 2>/dev/null | head -n1 || true)
fi
if [ -n "${CHROMIUM_BIN}" ]; then
  ln -sf "${CHROMIUM_BIN}" /usr/local/bin/chromium || true
  ln -sf "${CHROMIUM_BIN}" /usr/local/bin/chromium-browser || true
fi

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
