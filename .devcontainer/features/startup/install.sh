#!/usr/bin/env bash
# Auto-inserted by scripts/inject_prebaked_helpers.sh
# Source shared feature helpers (prebaked into image) or fall back to repository helper
if [ -n "${FEATURE_HELPERS_DIR:-}" ] && [ -f "${FEATURE_HELPERS_DIR}/helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "${FEATURE_HELPERS_DIR}/helpers.sh"
elif [ -f "../../../scripts/feature_helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "../../../scripts/feature_helpers.sh"
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

echo "startup: installing run-startup-scripts helper if present in repo"
if [ -f /usr/local/bin/run-startup-scripts.sh ]; then
  chmod +x /usr/local/bin/run-startup-scripts.sh || true
  echo "startup: /usr/local/bin/run-startup-scripts.sh present"
else
  if [ -f /tmp/run-startup-scripts.sh ]; then
    cp /tmp/run-startup-scripts.sh /usr/local/bin/run-startup-scripts.sh
    chmod +x /usr/local/bin/run-startup-scripts.sh
    echo "startup: installed run-startup-scripts from /tmp"
  else
    echo "startup: no run-startup-scripts.sh found in repo; skipping"
  fi
fi

# Provide a smoke check script
cat > /usr/local/bin/devcontainer-smoke <<'EOF'
#!/usr/bin/env bash
set -e
echo "devcontainer-smoke: OK"
EOF
chmod +x /usr/local/bin/devcontainer-smoke || true

echo "startup: done"
