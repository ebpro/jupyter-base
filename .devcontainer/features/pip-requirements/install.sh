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

echo "pip-requirements: installing pip requirements from /tmp/requirements.txt if present"
if [ -f /tmp/requirements.txt ]; then
  echo "pip-requirements: installing as non-root user if possible"
  NB_USER=${NB_USER:-jovyan}
  NB_UID=${NB_UID:-1001}
  NB_GID=${NB_GID:-1001}
  HOME_DIR="/home/${NB_USER}"
  mkdir -p "${HOME_DIR}/.cache/pip"
  chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/.cache/pip" || true
  # Run pip as the non-root user to avoid root warnings. Fall back to root if su fails.
  if command -v su >/dev/null 2>&1; then
    su - ${NB_USER} -c "bash -lc 'source ${HOME_DIR}/miniforge3/etc/profile.d/conda.sh >/dev/null 2>&1 || true; export PATH=\"${HOME_DIR}/miniforge3/bin:\$PATH\"; python3 -m pip install --no-cache-dir -r /tmp/requirements.txt'" || true
  else
    pip install --no-cache-dir -r /tmp/requirements.txt || true
  fi
else
  echo "pip-requirements: /tmp/requirements.txt not found; skipping"
fi

echo "pip-requirements: done"
