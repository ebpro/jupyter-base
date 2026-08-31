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

# Compute canonical ARCH once for use by multiple tools (kubectl, helm, kustomize)
arch_raw=$(uname -m)
case "$arch_raw" in
  x86_64|X86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  armv7*|armhf) ARCH=arm ;;
  *) ARCH="$arch_raw" ;;
esac

# Resolve versions from artefacts
if [ -f "${PWD}/artefacts/kubernetes-client/versions.json" ] || [ -f "${PWD}/artefacts/versions.json" ] || [ -f /tmp/versions.json ]; then
  resolve_version() {
    local tool="$1" v=""
    # prefer centralized resolver
    if command -v fh_resolve_version >/dev/null 2>&1; then
      v=$(fh_resolve_version "$tool" || true)
      if [ -n "$v" ]; then
        echo "$v"; return 0
      fi
    fi
    if [ -f "${PWD}/artefacts/kubernetes-client/versions.json" ]; then
      v=$(jq -r --arg t "$tool" '.tools[$t] // empty' "${PWD}/artefacts/kubernetes-client/versions.json" 2>/dev/null || true)
      [ -n "$v" ] && { echo "$v"; return 0; }
    fi
    if [ -f "${PWD}/artefacts/versions.json" ]; then
      v=$(jq -r --arg t "$tool" '.tools[$t] // empty' "${PWD}/artefacts/versions.json" 2>/dev/null || true)
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
  KUBECTL_URL="https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"
  # download_direct URL TOOL [INSTALL_DIR] [EXTRACT]
  download_direct "${KUBECTL_URL}" "kubectl" "${LOCAL_BIN}" "false"
fi

# Install helm (GitHub release tarball)
if [ -n "${HELM_VERSION}" ]; then
  echo "kubernetes-client: installing helm ${HELM_VERSION}"
  # Download helm from get.helm.sh (assets hosted on their CDN)
  echo "kubernetes-client: installing helm ${HELM_VERSION}"
  # Ensure the tag used in the filename includes a leading 'v' (get.helm.sh filenames are 'helm-vX.Y.Z...')
  if [[ "${HELM_VERSION}" == v* ]]; then
    HELM_TAG="${HELM_VERSION}"
  else
    HELM_TAG="v${HELM_VERSION}"
  fi
  HELM_URL="https://get.helm.sh/helm-${HELM_TAG}-linux-${ARCH}.tar.gz"
  # use download_direct which will extract and pick the `helm` binary from the archive
  download_direct "${HELM_URL}" "helm" "${LOCAL_BIN}" "true"
fi

# Install kustomize (GitHub release tarball)
if [ -n "${KUSTOMIZE_VERSION}" ]; then
  echo "kubernetes-client: installing kustomize ${KUSTOMIZE_VERSION}"
  # For kustomize, upstream release tag includes a repo prefix 'kustomize/v{version}'
  # GitHub release download path uses percent-encoding for '/', e.g. 'kustomize%2Fv5.8.0'
  KUSTOMIZE_VER_NOV=${KUSTOMIZE_VERSION#v}
  KUSTOMIZE_TAG_ESC="kustomize%2Fv${KUSTOMIZE_VER_NOV}"
  KUSTOMIZE_URL="https://github.com/kubernetes-sigs/kustomize/releases/download/${KUSTOMIZE_TAG_ESC}/kustomize_v${KUSTOMIZE_VER_NOV}_linux_${ARCH}.tar.gz"
  download_direct "${KUSTOMIZE_URL}" "kustomize" "${LOCAL_BIN}" "true"
fi

chown -R ${NB_UID}:${NB_GID} "${LOCAL_BIN}" || true
echo "kubernetes-client: installed kubectl, helm, kustomize into ${LOCAL_BIN}"
