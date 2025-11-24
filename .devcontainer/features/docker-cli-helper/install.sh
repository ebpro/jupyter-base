#!/usr/bin/env bash
set -euo pipefail

NB_USER=${NB_USER:-jovyan}
NB_UID=${NB_UID:-1001}
NB_GID=${NB_GID:-1001}

echo "docker-cli-helper: creating docker group (if missing) and adding ${NB_USER}"
if ! getent group docker >/dev/null 2>&1; then
  groupadd -f -g 999 docker || true
fi
usermod -aG docker ${NB_USER} || true

# Helper script to check Docker socket
cat > /usr/local/bin/check-docker-socket <<'EOF'
#!/usr/bin/env bash
if [ -S /var/run/docker.sock ]; then
  echo "/var/run/docker.sock exists"
  ls -l /var/run/docker.sock
else
  echo "/var/run/docker.sock is missing"
  exit 1
fi
EOF
chmod +x /usr/local/bin/check-docker-socket || true

echo "docker-cli-helper: done"
