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

NB_USER=${NB_USER:-jovyan}
NB_UID=${NB_UID:-1001}
NB_GID=${NB_GID:-1001}
ENABLE_BUILDKIT=${ENABLEBUILDKIT:-true}
STORAGE_DRIVER=${STORAGEDRIVER:-overlay2}

echo "docker-dind: installing Docker Engine and Docker Compose"

# Install Docker Engine
if ! command -v docker >/dev/null 2>&1; then
  if command -v apt_install >/dev/null 2>&1; then
    apt_install ca-certificates curl gnupg lsb-release
  else
    apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg lsb-release
  fi

  # Add Docker's official GPG key
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  # Set up Docker repository
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt-get update
  apt-get install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# Create docker group and add user
if ! getent group docker >/dev/null 2>&1; then
  groupadd -f docker
fi
usermod -aG docker ${NB_USER} || true

# Configure Docker daemon
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<EOF
{
  "storage-driver": "${STORAGE_DRIVER}",
  "features": {
    "buildkit": ${ENABLE_BUILDKIT}
  },
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

# Create systemd service override for rootless operation (if systemd available)
if command -v systemctl >/dev/null 2>&1; then
  mkdir -p /etc/systemd/system/docker.service.d
  cat > /etc/systemd/system/docker.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock
EOF
fi

# Create helper script to start Docker daemon
cat > /usr/local/bin/start-dockerd <<'EOF'
#!/usr/bin/env bash
set -e

# Ensure directories exist
mkdir -p /var/lib/docker /var/run

# Clean up stale socket
rm -f /var/run/docker.sock /var/run/docker.pid

# Start Docker daemon
echo "Starting Docker daemon..."
exec dockerd \
  --host=unix:///var/run/docker.sock \
  --host=tcp://0.0.0.0:2375 \
  --tls=false
EOF
chmod +x /usr/local/bin/start-dockerd

# Install docker-compose standalone (for compatibility)
if ! command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_VERSION="2.24.0"
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) COMPOSE_ARCH="x86_64" ;;
    aarch64) COMPOSE_ARCH="aarch64" ;;
    *) COMPOSE_ARCH="x86_64" ;;
  esac

  curl -fsSL "https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-linux-${COMPOSE_ARCH}" \
    -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
fi

# Set up environment for user
cat >> /home/${NB_USER}/.bashrc <<'EOF'

# Docker DinD environment
export DOCKER_HOST=unix:///var/run/docker.sock
EOF

if [ -f /home/${NB_USER}/.zshrc ]; then
  cat >> /home/${NB_USER}/.zshrc <<'EOF'

# Docker DinD environment
export DOCKER_HOST=unix:///var/run/docker.sock
EOF
fi

chown -R ${NB_UID}:${NB_GID} /home/${NB_USER}/.bashrc /home/${NB_USER}/.zshrc 2>/dev/null || true

echo "docker-dind: Docker daemon installed. Use 'start-dockerd' to start the daemon."
echo "docker-dind: NOTE: Container must run with --privileged or use Sysbox runtime for security."
