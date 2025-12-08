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
