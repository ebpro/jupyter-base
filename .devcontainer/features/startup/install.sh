#!/usr/bin/env bash
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
