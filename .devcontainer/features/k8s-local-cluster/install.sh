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
HOME_DIR="/home/${NB_USER}"
LOCAL_BIN="${HOME_DIR}/bin"
AUTO_CREATE=${AUTOCREATECLUSTER:-false}
CLUSTER_NAME=${CLUSTERNAME:-devcluster}
AGENTS=${AGENTS:-2}

mkdir -p "${LOCAL_BIN}"

# Resolve k3d version
if [ -f "${PWD}/Artefacts/features/k8s-local-cluster/versions.json" ] || [ -f "${PWD}/Artefacts/versions.json" ] || [ -f /tmp/versions.json ]; then
  resolve_version() {
    local tool="$1" v=""
    if [ -f "${PWD}/Artefacts/features/k8s-local-cluster/versions.json" ]; then
      v=$(jq -r --arg t "$tool" '.tools[$t] // empty' "${PWD}/Artefacts/features/k8s-local-cluster/versions.json" 2>/dev/null || true)
      [ -n "$v" ] && { echo "$v"; return 0; }
    fi
    if [ -f "${PWD}/Artefacts/versions.json" ]; then
      v=$(jq -r --arg t "$tool" '.tools[$t] // empty' "${PWD}/Artefacts/versions.json" 2>/dev/null || true)
      [ -n "$v" ] && { echo "$v"; return 0; }
    fi
    if [ -f /tmp/versions.json ]; then
      v=$(jq -r --arg t "$tool" '.tools[$t] // empty' /tmp/versions.json 2>/dev/null || true)
      [ -n "$v" ] && { echo "$v"; return 0; }
    fi
    echo ""
  }

  K3D_VERSION=$(resolve_version "k3d")
else
  echo "k8s-local-cluster: no versions.json found, using latest" >&2
  K3D_VERSION="5.6.0"
fi

# Install k3d (GitHub release binary)
if [ -n "${K3D_VERSION}" ]; then
  echo "k8s-local-cluster: installing k3d ${K3D_VERSION}"
  download_github_release "k3d-io/k3d" "${K3D_VERSION}" "k3d-linux-\${ARCH}" "${LOCAL_BIN}/k3d" ""
fi

# Create helper script to manage clusters
cat > "${LOCAL_BIN}/k3d-cluster-setup" <<EOF
#!/usr/bin/env bash
set -e

CLUSTER_NAME=\${1:-${CLUSTER_NAME}}
AGENTS=\${2:-${AGENTS}}

echo "Creating k3d cluster: \${CLUSTER_NAME} with \${AGENTS} agents..."

# Create cluster with multiple agents and port mappings
k3d cluster create "\${CLUSTER_NAME}" \\
  --agents "\${AGENTS}" \\
  --port "8080:80@loadbalancer" \\
  --port "8443:443@loadbalancer" \\
  --api-port 6443 \\
  --wait \\
  --timeout 120s

echo "Cluster \${CLUSTER_NAME} created successfully!"
echo "Nodes:"
kubectl get nodes

echo ""
echo "To delete this cluster: k3d cluster delete \${CLUSTER_NAME}"
echo "To list clusters: k3d cluster list"
EOF
chmod +x "${LOCAL_BIN}/k3d-cluster-setup"

# Create helper script to setup common CI/CD tools
cat > "${LOCAL_BIN}/k3d-setup-cicd" <<'EOF'
#!/usr/bin/env bash
set -e

CLUSTER_NAME=${1:-devcluster}

echo "Setting up CI/CD tools in cluster: ${CLUSTER_NAME}..."

# Ensure cluster exists and is running
if ! k3d cluster list | grep -q "${CLUSTER_NAME}"; then
  echo "Error: Cluster ${CLUSTER_NAME} does not exist. Create it first with k3d-cluster-setup."
  exit 1
fi

# Add Helm repositories
echo "Adding Helm repositories..."
helm repo add harbor https://helm.goharbor.io
helm repo add sonarqube https://SonarSource.github.io/helm-chart-sonarqube
helm repo add sonatype https://sonatype.github.io/helm3-charts/
helm repo update

echo ""
echo "CI/CD Helm repos configured. Example installations:"
echo ""
echo "  # Install Harbor (container registry):"
echo "  helm install harbor harbor/harbor --create-namespace --namespace harbor"
echo ""
echo "  # Install SonarQube (code quality):"
echo "  helm install sonarqube sonarqube/sonarqube --create-namespace --namespace sonarqube"
echo ""
echo "  # Install Nexus (artifact repository):"
echo "  helm install nexus sonatype/nexus-repository-manager --create-namespace --namespace nexus"
EOF
chmod +x "${LOCAL_BIN}/k3d-setup-cicd"

# Create startup script if auto-create is enabled
if [ "${AUTO_CREATE}" = "true" ]; then
  cat > "${HOME_DIR}/.k3d-autostart" <<EOF
#!/usr/bin/env bash
# Auto-create k3d cluster on startup
if ! k3d cluster list 2>/dev/null | grep -q "${CLUSTER_NAME}"; then
  echo "Auto-creating k3d cluster: ${CLUSTER_NAME}..."
  k3d-cluster-setup "${CLUSTER_NAME}" "${AGENTS}"
fi
EOF
  chmod +x "${HOME_DIR}/.k3d-autostart"

  # Add to user's shell rc files
  for rcfile in "${HOME_DIR}/.bashrc" "${HOME_DIR}/.zshrc"; do
    if [ -f "$rcfile" ]; then
      if ! grep -q ".k3d-autostart" "$rcfile"; then
        echo "" >> "$rcfile"
        echo "# Auto-start k3d cluster" >> "$rcfile"
        echo "[ -f ~/.k3d-autostart ] && ~/.k3d-autostart &" >> "$rcfile"
      fi
    fi
  done
fi

chown -R ${NB_UID}:${NB_GID} "${LOCAL_BIN}" "${HOME_DIR}/.k3d-autostart" 2>/dev/null || true

echo "k8s-local-cluster: k3d installed into ${LOCAL_BIN}"
echo "k8s-local-cluster: Use 'k3d-cluster-setup' to create a cluster"
echo "k8s-local-cluster: Use 'k3d-setup-cicd' to configure CI/CD Helm repos"
