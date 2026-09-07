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

# Shared libraries required by the Chromium binary that 'quarto install
# chromium' downloads (verified via ldd against the bundled build:
# libnss3, libnspr4, libatk*, libatk-bridge*, libcups, libdrm,
# libxkbcommon, libXcomposite, libXdamage, libXfixes, libXrandr, libgbm,
# libpango, libcairo, libgtk-3, libasound, libatspi, libxshmfence).
# Without these the binary dies at startup with
# "error while loading shared libraries: libnss3.so", which Quarto's
# server-side render reports only as a bare "ERROR: AssertionError:".
# (noble 24.04 t64 package names; verified with apt-get install --dry-run.)
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    libnss3 \
    libnspr4 \
    libatk1.0-0t64 \
    libatk-bridge2.0-0t64 \
    libcups2t64 \
    libdrm2 \
    libxkbcommon0 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxrandr2 \
    libgbm1 \
    libpango-1.0-0 \
    libcairo2 \
    libasound2t64 \
    libatspi2.0-0t64 \
    libgtk-3-0t64 \
    libxshmfence1
rm -rf /var/lib/apt/lists/*

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
    "${HOME_DIR}/.local/share/quarto/chromium/linux-"*/chrome-linux/chrome \
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

  local search_dir found candidate
  for search_dir in \
    "${HOME_DIR}/.local/share/quarto/chromium" \
    "${HOME_DIR}/.local/share/quarto" \
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
    found=$(
      find "${search_dir}" \( -type f -o -type l \) \( -name chrome -o -name chromium -o -name chromium-browser -o -name headless_shell \) 2>/dev/null |
        while IFS= read -r candidate; do
          if [ -x "${candidate}" ]; then
            printf '%s\n' "${candidate}"
            break
          fi
        done
    )
    if [ -n "${found}" ]; then
      printf '%s\n' "${found}"
      return 0
    fi
  done

  return 1
}

# Wrap the real Chromium binary IN PLACE with a CI-safe shim.
#
# Why: courseware render CI runs the container as root in a restricted
# docker context. Quarto's own browser spawn (criClient in quarto.js)
# passes --no-sandbox --disable-gpu but NOT --disable-dev-shm-usage, and
# the default 64 MB /dev/shm is too small for headless Chrome, so the
# Chromium child dies at startup and Quarto's error path reports a bare
# "ERROR: AssertionError:" instead of the real cause. The shim bakes in
# the CI-safe flags for every invocation.
#
# In-place wrapping keeps all of Quarto's discovery routes on the shim:
# the /usr/local/bin + ~/.local/bin symlinks created below, and Quarto's
# own install dir (~/.local/share/quarto/chromium/...), all resolve to
# this same file.
wrap_chromium_shim() {
  local bin="$1"
  local real bin_name resolved
  resolved="$(readlink -f "${bin}" 2>/dev/null || true)"
  if [ -n "${resolved}" ]; then
    bin="${resolved}"
  fi
  real="${bin}.real"
  bin_name="$(basename "${bin}")"

  # Idempotent: a shim is already in place.
  if [ -e "${bin}" ] && head -n 5 "${bin}" 2>/dev/null | grep -q 'solen-chromium-shim'; then
    echo "quarto-chromium: shim already in place at ${bin}"
    return 0
  fi

  if [ -e "${bin}" ]; then
    # Fresh binary at the public path (first run, or 'quarto install
    # chromium' replaced the shim on a re-run): move it aside, overwriting
    # any stale .real.
    mv -f "${bin}" "${real}"
  elif [ ! -e "${real}" ]; then
    echo "quarto-chromium: ERROR: no Chromium binary at ${bin} to wrap" >&2
    return 1
  fi
  # else: public path gone but .real remains — fall through and re-write
  # the shim pointing at it.

  cat > "${bin}" <<SHIM
#!/bin/sh
# solen-chromium-shim: CI-safe flags for headless Chromium in restricted
# containers (baked by features/quarto-chromium; original: ${bin_name}.real)
# Resolve our canonical path first: this shim is commonly invoked through
# the /usr/local/bin + ~/.local/bin symlinks, where \$0 would point at the
# symlink and dirname(\$0) would miss ${bin_name}.real next to the original.
self="\$(readlink -f "\$0" 2>/dev/null || echo "\$0")"
exec "\$(dirname "\$self")/${bin_name}.real" --no-sandbox --disable-gpu --disable-dev-shm-usage "\$@"
SHIM
  chmod 0755 "${bin}"
  chown "${NB_UID}":"${NB_GID}" "${bin}" "${real}" || true
  echo "quarto-chromium: installed CI-safe shim at ${bin} (original: ${real})"
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

  # Bake the CI-safe flags into the binary itself (idempotent).
  wrap_chromium_shim "${CHROMIUM_BIN}"
else
  echo "quarto-chromium: WARNING: Chromium binary not found after installation" >&2
  for search_dir in \
    "${HOME_DIR}/.local/share/quarto/chromium" \
    "${HOME_DIR}/.local/share/quarto" \
    "${HOME_DIR}/.quarto" \
    "${HOME_DIR}/.cache" \
    /root/.quarto \
    /root/.cache \
    /tmp \
    /var/cache
  do
    [ -d "${search_dir}" ] || continue
    find "${search_dir}" -maxdepth 6 \( -type f -o -type l \) \( -name chrome -o -name chromium -o -name chromium-browser -o -name headless_shell \) 2>/dev/null | head -n 20 || true
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
