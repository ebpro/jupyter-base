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
  CI=true "${QUARTO_BIN}" install --no-prompt --log "${HOME}/.quarto-chromium-install.log" --log-level debug chromium \
    || CI=true "${QUARTO_BIN}" install chromium --no-prompt \
    || true
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
    "${HOME_DIR}/.local/share/quarto-chromium/chromium" \
    "${HOME_DIR}/.local/share/quarto-chromium/chromium-browser" \
    "${HOME_DIR}/.local/share/quarto-chromium/chrome" \
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
    "${HOME_DIR}/.local/share/quarto-chromium" \
    /opt/quarto \
    /usr/local/bin \
    /usr/bin \
    /usr/lib \
    "${HOME_DIR}/.cache" \
    /root/.quarto \
    /root/.cache \
    /tmp \
    /var/cache
  do
    [ -d "${search_dir}" ] || continue
    found=$(find "${search_dir}" -type f \( -name chrome -o -name chromium -o -name chromium-browser -o -name headless_shell \) -perm -111 2>/dev/null | head -n1 || true)
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

  PERSIST_DIR="${HOME_DIR}/.local/share/quarto-chromium"
  if [[ "${CHROMIUM_BIN}" == *"/.cache/*" || "${CHROMIUM_BIN}" == /root/* || "${CHROMIUM_BIN}" == /tmp/* || "${CHROMIUM_BIN}" == /var/cache/* ]]; then
    src_dir="$(dirname "${CHROMIUM_BIN}")"
    src_name="$(basename "${src_dir}")"
    bin_name="$(basename "${CHROMIUM_BIN}")"
    mkdir -p "${PERSIST_DIR}"

    case "${src_name}" in
      tmp|var|cache|root|home|opt|usr|etc)
        cp -a "${CHROMIUM_BIN}" "${PERSIST_DIR}/${bin_name}" || true
        if [ -x "${PERSIST_DIR}/${bin_name}" ]; then
          CHROMIUM_BIN="${PERSIST_DIR}/${bin_name}"
          echo "quarto-chromium: copied Chromium binary to ${CHROMIUM_BIN}"
        else
          echo "quarto-chromium: WARNING: failed to copy Chromium binary to ${PERSIST_DIR}/${bin_name}" >&2
        fi
        ;;
      *)
        dest_dir="${PERSIST_DIR}/${src_name}"
        if [ -d "${dest_dir}" ]; then
          rm -rf "${dest_dir}"
        fi
        cp -a "${src_dir}" "${dest_dir}" || true
        if [ -x "${dest_dir}/${bin_name}" ]; then
          CHROMIUM_BIN="${dest_dir}/${bin_name}"
          echo "quarto-chromium: copied Chromium runtime to ${CHROMIUM_BIN}"
        else
          echo "quarto-chromium: WARNING: copied Chromium runtime but expected binary not found at ${dest_dir}/${bin_name}" >&2
        fi
        ;;
    esac
  fi

  chmod +x "${CHROMIUM_BIN}" || true
  chown "${NB_UID}":"${NB_GID}" "${CHROMIUM_BIN}" || true
  if [ -d "${PERSIST_DIR}" ]; then
    chown -R "${NB_UID}":"${NB_GID}" "${PERSIST_DIR}" || true
  fi
  mkdir -p "${HOME_DIR}/.local/bin" || true
  ln -sf "${CHROMIUM_BIN}" /usr/local/bin/chromium || true
  ln -sf "${CHROMIUM_BIN}" /usr/local/bin/chromium-browser || true
  ln -sf "${CHROMIUM_BIN}" "${HOME_DIR}/.local/bin/chromium" || true
  ln -sf "${CHROMIUM_BIN}" "${HOME_DIR}/.local/bin/chromium-browser" || true
  chown "${NB_UID}":"${NB_GID}" "${HOME_DIR}/.local/bin/chromium" "${HOME_DIR}/.local/bin/chromium-browser" || true
else
  echo "quarto-chromium: WARNING: Chromium binary not found after installation" >&2
  for search_dir in \
    "${HOME_DIR}/.quarto" \
    "${HOME_DIR}/.cache" \
    /root/.quarto \
    /root/.cache \
    /tmp \
    /var/cache
  do
    [ -d "${search_dir}" ] || continue
    find "${search_dir}" -maxdepth 5 -type f \( -name chrome -o -name chromium -o -name chromium-browser -o -name headless_shell \) 2>/dev/null | head -n 20 || true
  done
  if [ -f "${HOME_DIR}/.quarto-chromium-install.log" ]; then
    echo "quarto-chromium: Quarto install log tail:" >&2
    tail -n 40 "${HOME_DIR}/.quarto-chromium-install.log" >&2 || true
  fi
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
