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

# Resolve Docker version from Artefacts/versions.json
DOCKER_VERSION=""
DOCKER_COMPOSE_VERSION=""
for artefacts_dir in /tmp/Artefacts /workspace/Artefacts /tmp/build-context/Artefacts; do
  if [ -f "${artefacts_dir}/versions.json" ]; then
    DOCKER_VERSION=$(jq -r '.tools."docker-ce" // "27.5.1"' "${artefacts_dir}/versions.json" 2>/dev/null || echo "27.5.1")
    DOCKER_COMPOSE_VERSION=$(jq -r '.tools."docker-compose" // "2.39.3"' "${artefacts_dir}/versions.json" 2>/dev/null || echo "2.39.3")
    break
  fi
done
DOCKER_VERSION=${DOCKER_VERSION:-27.5.1}
DOCKER_COMPOSE_VERSION=${DOCKER_COMPOSE_VERSION:-2.39.3}

echo "docker-dind: installing Docker Engine ${DOCKER_VERSION} and Docker Compose ${DOCKER_COMPOSE_VERSION}"

# Install Docker Engine
if ! command -v docker >/dev/null 2>&1; then
  if command -v apt_install >/dev/null 2>&1; then
    apt_install ca-certificates curl gnupg lsb-release
  else
    apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg lsb-release
  fi

  # Detect OS (Ubuntu or Debian)
  . /etc/os-release
  DOCKER_OS="${ID}"  # Will be "ubuntu" or "debian"
  DOCKER_CODENAME="${VERSION_CODENAME}"  # e.g., "noble"
  
  echo "docker-dind: detected OS=${DOCKER_OS} CODENAME=${DOCKER_CODENAME}"
  
  # Remove any stale Docker repo configs
  rm -f /etc/apt/sources.list.d/docker.list
  rm -f /etc/apt/keyrings/docker.gpg
  
  # Add Docker's official GPG key
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${DOCKER_OS}/gpg" | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  # Set up Docker repository
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${DOCKER_OS} ${DOCKER_CODENAME} stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt-get update
  
  # Pin Docker version if specified
  if [ -n "${DOCKER_VERSION}" ] && [ "${DOCKER_VERSION}" != "latest" ]; then
    # Docker package version format: 5:VERSION-1~ubuntu.24.04~CODENAME
    DOCKER_PKG="docker-ce=5:${DOCKER_VERSION}-1~ubuntu.24.04~${DOCKER_CODENAME}"
    DOCKER_CLI_PKG="docker-ce-cli=5:${DOCKER_VERSION}-1~ubuntu.24.04~${DOCKER_CODENAME}"
    echo "docker-dind: installing pinned version ${DOCKER_PKG}"
  else
    DOCKER_PKG="docker-ce"
    DOCKER_CLI_PKG="docker-ce-cli"
    echo "docker-dind: installing latest Docker CE"
  fi
  
  apt-get install -y --no-install-recommends \
    ${DOCKER_PKG} ${DOCKER_CLI_PKG} containerd.io docker-buildx-plugin docker-compose-plugin
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
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) COMPOSE_ARCH="x86_64" ;;
    aarch64) COMPOSE_ARCH="aarch64" ;;
    *) COMPOSE_ARCH="x86_64" ;;
  esac

  curl -fsSL "https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-linux-${COMPOSE_ARCH}" \
    -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
fi

# Create health check script
cat > /usr/local/bin/docker-health <<'EOF'
#!/usr/bin/env bash
set -e
if ! docker info >/dev/null 2>&1; then
  echo "❌ Docker daemon not responding"
  exit 1
fi
echo "✅ Docker daemon healthy"
docker version --format 'Server: {{.Server.Version}}'
EOF
chmod +x /usr/local/bin/docker-health

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

# Create startup script for automatic daemon start
mkdir -p /etc/startup.d
cat > /etc/startup.d/10-dockerd.sh <<'EOF'
#!/usr/bin/env bash
# Auto-start Docker daemon if not running
if command -v dockerd >/dev/null 2>&1; then
  if ! docker info >/dev/null 2>&1; then
    echo "Starting Docker daemon..."
    nohup /usr/local/bin/start-dockerd > /var/log/dockerd.log 2>&1 &
    # Wait for daemon to be ready
    for i in {1..30}; do
      if docker info >/dev/null 2>&1; then
        echo "✅ Docker daemon started"
        break
      fi
      sleep 1
    done
  else
    echo "✅ Docker daemon already running"
  fi
fi
EOF
chmod +x /etc/startup.d/10-dockerd.sh

echo "docker-dind: Docker ${DOCKER_VERSION} installed with Compose ${DOCKER_COMPOSE_VERSION}"
echo "docker-dind: Daemon will auto-start via /etc/startup.d/10-dockerd.sh"
echo "docker-dind: Manual start: 'start-dockerd' | Health check: 'docker-health'"
echo "docker-dind: NOTE: Container must run with --privileged or use Sysbox runtime for security."
