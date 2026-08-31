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

echo "bundle-cicd-teaching: Complete CI/CD teaching environment ready"
echo ""
echo "📦 Available tools:"
echo "  - Docker-in-Docker (docker, docker-compose)"
echo "  - Kubernetes client (kubectl, helm, kustomize)"
echo "  - k3d for local clusters"
echo "  - k9s for cluster debugging"
echo "  - GitHub CLI (gh)"
echo "  - Tilt for development workflows"
echo ""
echo "🚀 Quick start commands:"
echo "  k3d-cluster-setup mylab 2     # Create 3-node cluster"
echo "  k3d-setup-cicd mylab           # Configure CI/CD Helm repos"
echo "  kubectl get nodes              # Verify cluster"
echo ""
echo "📚 CI/CD stack deployments:"
echo "  helm install harbor harbor/harbor --namespace harbor --create-namespace"
echo "  helm install sonarqube sonarqube/sonarqube --namespace sonarqube --create-namespace"
echo "  helm install nexus sonatype/nexus-repository-manager --namespace nexus --create-namespace"
echo ""
echo "🔧 Helpful commands:"
echo "  k9s                            # Terminal UI for cluster"
echo "  k3d cluster list               # List all clusters"
echo "  docker ps                      # See running containers"
echo ""
echo "✅ Ready for CI/CD teaching with Harbor, SonarQube, Nexus, and GitLab workflows!"
