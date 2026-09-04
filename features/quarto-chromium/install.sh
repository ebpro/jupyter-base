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

find_chromium_bin() {
  local c
  for c in \
    "${HOME_DIR}/.quarto/bin/chromium" \
    "${HOME_DIR}/.quarto/bin/chromium-browser" \
    "${HOME_DIR}/.quarto/bin/chrome" \
    /usr/bin/chromium \
    /usr/bin/chromium-browser \
    /usr/local/bin/chromium \
    /usr/local/bin/chromium-browser
  do
    if [ -x "$c" ]; then
      printf '%s\n' "$c"
      return 0
    fi
  done

  local search_dir found
  for search_dir in \
    "${HOME_DIR}/.quarto" \
    "${HOME_DIR}/.local/bin" \
    /opt/quarto \
    /usr/local/bin \
    /usr/bin \
    /usr/lib
  do
    [ -d "${search_dir}" ] || continue
    found=$(find "${search_dir}" -type f \( -name chrome -o -name chromium -o -name chromium-browser \) -perm -111 2>/dev/null | head -n1 || true)
    if [ -n "${found}" ]; then
      printf '%s\n' "${found}"
      return 0
    fi
  done

  return 1
}

CHROMIUM_BIN="$(find_chromium_bin || true)"
if [ -n "${CHROMIUM_BIN}" ]; then
  echo "quarto-chromium: found Chromium binary at ${CHROMIUM_BIN}"
  chmod +x "${CHROMIUM_BIN}" || true
  chown "${NB_UID}":"${NB_GID}" "${CHROMIUM_BIN}" || true
  mkdir -p "${HOME_DIR}/.local/bin" || true
  ln -sf "${CHROMIUM_BIN}" /usr/local/bin/chromium || true
  ln -sf "${CHROMIUM_BIN}" /usr/local/bin/chromium-browser || true
  ln -sf "${CHROMIUM_BIN}" "${HOME_DIR}/.local/bin/chromium" || true
  ln -sf "${CHROMIUM_BIN}" "${HOME_DIR}/.local/bin/chromium-browser" || true
  chown "${NB_UID}":"${NB_GID}" "${HOME_DIR}/.local/bin/chromium" "${HOME_DIR}/.local/bin/chromium-browser" || true
else
  echo "quarto-chromium: WARNING: Chromium binary not found after installation" >&2
  find "${HOME_DIR}/.quarto" -maxdepth 4 -type f 2>/dev/null | head -n 20 || true
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
