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

echo "pip-requirements: installing pip requirements from /tmp/requirements.txt if present"
if [ -f /tmp/requirements.txt ]; then
  echo "pip-requirements: installing as non-root user if possible"
  NB_USER=${NB_USER:-jovyan}
  NB_UID=${NB_UID:-1001}
  NB_GID=${NB_GID:-1001}
  HOME_DIR="/home/${NB_USER}"
  mkdir -p "${HOME_DIR}/.cache/pip"
  chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/.cache/pip" || true
  # ensure IPython dir exists and is owned by the notebook user
  mkdir -p "${HOME_DIR}/.ipython" || true
  chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/.ipython" || true
  # Run pip as the non-root user to avoid root warnings. Fall back to root if su fails.
  if command -v su >/dev/null 2>&1; then
    TMP_SCRIPT="/tmp/pip-requirements-install-${NB_USER}.sh"
    cat > "${TMP_SCRIPT}" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
source "$HOME/miniforge3/etc/profile.d/conda.sh" >/dev/null 2>&1 || true
export PATH="$HOME/miniforge3/bin:$PATH"
python3 -m pip install -r /tmp/requirements.txt || true
BASH
    chmod +x "${TMP_SCRIPT}" || true
    su - ${NB_USER} -s /bin/bash -c "${TMP_SCRIPT}" || true
    rm -f "${TMP_SCRIPT}" || true
  else
    # Run pip with HOME set to the notebook user's home so cache is written there
    HOME="${HOME_DIR}" python3 -m pip install -r /tmp/requirements.txt || true
    # ensure user caches and ipython dir are owned by the notebook user
    chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/.cache" "${HOME_DIR}/.local" "${HOME_DIR}/.ipython" >/dev/null 2>&1 || true
  fi
else
  echo "pip-requirements: /tmp/requirements.txt not found; skipping"
fi

echo "pip-requirements: done"
