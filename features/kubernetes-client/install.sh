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

NB_USER=${NB_USER:-jovyan}
NB_UID=${NB_UID:-1001}
NB_GID=${NB_GID:-1001}
HOME_DIR="/home/${NB_USER}"
LOCAL_BIN="${HOME_DIR}/bin"

mkdir -p "${LOCAL_BIN}"

# Resolve versions from Artefacts
if [ -f "${PWD}/artefacts/kubernetes-client/versions.json" ] || [ -f "${PWD}/Artefacts/versions.json" ] || [ -f /tmp/versions.json ]; then
  resolve_version() {
    local tool="$1" v=""
    if [ -f "${PWD}/artefacts/kubernetes-client/versions.json" ]; then
      v=$(jq -r --arg t "$tool" '.tools[$t] // empty' "${PWD}/artefacts/kubernetes-client/versions.json" 2>/dev/null || true)
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

  KUBECTL_VERSION=$(resolve_version "kubectl")
  HELM_VERSION=$(resolve_version "helm")
  KUSTOMIZE_VERSION=$(resolve_version "kustomize")
else
  echo "kubernetes-client: no versions.json found, skipping" >&2
  exit 0
fi

# Install kubectl (direct download from dl.k8s.io)
if [ -n "${KUBECTL_VERSION}" ]; then
  echo "kubernetes-client: installing kubectl ${KUBECTL_VERSION}"
  KUBECTL_URL="https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/\${ARCH}/kubectl"
  download_direct "kubectl" "${KUBECTL_VERSION}" "${KUBECTL_URL}" "${LOCAL_BIN}/kubectl"
fi

# Install helm (GitHub release tarball)
if [ -n "${HELM_VERSION}" ]; then
  echo "kubernetes-client: installing helm ${HELM_VERSION}"
  download_github_release "helm/helm" "${HELM_VERSION}" "helm-v\${VERSION}-linux-\${ARCH}.tar.gz" "${LOCAL_BIN}/helm" "linux-\${ARCH}/helm"
fi

# Install kustomize (GitHub release tarball)
if [ -n "${KUSTOMIZE_VERSION}" ]; then
  echo "kubernetes-client: installing kustomize ${KUSTOMIZE_VERSION}"
  download_github_release "kubernetes-sigs/kustomize" "${KUSTOMIZE_VERSION}" "kustomize_v\${VERSION}_linux_\${ARCH}.tar.gz" "${LOCAL_BIN}/kustomize" "kustomize" "kustomize/"
fi

chown -R ${NB_UID}:${NB_GID} "${LOCAL_BIN}" || true
echo "kubernetes-client: installed kubectl, helm, kustomize into ${LOCAL_BIN}"
