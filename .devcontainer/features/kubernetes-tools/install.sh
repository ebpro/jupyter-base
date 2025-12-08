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

NB_USER=${NB_USER:-jovyan}
NB_UID=${NB_UID:-1001}
NB_GID=${NB_GID:-1001}
HOME_DIR="/home/${NB_USER}"
LOCAL_BIN="${HOME_DIR}/bin"

mkdir -p "${LOCAL_BIN}"

if [ -f "${PWD}/Artefacts/features/kubernetes-tools/versions.json" ] || [ -f "${PWD}/Artefacts/versions.json" ] || [ -f /tmp/versions.json ]; then
  # prefer per-feature versions, then central Artefacts, then /tmp
  resolve_version() {
    local tool="$1" v=""
    if [ -f "${PWD}/Artefacts/features/kubernetes-tools/versions.json" ]; then
      v=$(jq -r --arg t "$tool" '.tools[$t] // empty' "${PWD}/Artefacts/features/kubernetes-tools/versions.json" 2>/dev/null || true)
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
  K9S_VERSION=$(resolve_version "k9s")
  KUSTOMIZE_VERSION=$(resolve_version "kustomize")
  MINIKUBE_VERSION=$(resolve_version "minikube")
else
  echo "kubernetes-tools: no versions.json found in Artefacts or /tmp, skipping" >&2
  exit 0
fi

# Normalize architecture using centralized helper when available
if [ -f "${PWD}/scripts/arch.sh" ]; then
  # shellcheck source=/dev/null
  source "${PWD}/scripts/arch.sh"
  ARCH=$(arch_map "${TARGETPLATFORM:-$(uname -m)}")
else
  ARCH=$(case "$(uname -m)" in x86_64|X86_64) echo "amd64" ;; aarch64|arm64) echo "arm64" ;; *) echo "amd64" ;; esac)
fi

if command -v toolcache-get >/dev/null 2>&1; then
  TOOLCACHE=toolcache-get
else
  TOOLCACHE="/usr/local/bin/toolcache-get"
fi

install_and_link() {
  name=$1; ver=$2; url=$3; chksum=$4; extract_path=$5
  echo "kubernetes-tools: toolcache install $name $ver"
  prefix=$($TOOLCACHE "$name" "$ver" "$url" "$chksum" "$extract_path" || true)
  if [ -z "$prefix" ]; then
    echo "kubernetes-tools: failed to install $name via toolcache-get" >&2
    return 1
  fi
  # find candidate binaries under prefix
  for bin in kubectl helm k9s kustomize minikube; do
    if [ -x "$prefix/bin/$bin" ]; then
      ln -sf "$prefix/bin/$bin" "${LOCAL_BIN}/$bin"
    else
      found=$(find "$prefix" -type f -name "$bin" -perm /111 -print -quit 2>/dev/null || true)
      if [ -n "$found" ]; then
        mkdir -p "${LOCAL_BIN}"
        ln -sf "$found" "${LOCAL_BIN}/$bin"
      fi
    fi
  done
}

if [ -n "${KUBECTL_VERSION}" ]; then
  echo "kubernetes-tools: installing kubectl ${KUBECTL_VERSION} into toolcache"
  KUBECTL_URL="https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"
  KUB_CHKSUM=""
  resolve_checksum() {
    local tool="$1" ver="$2" arch="$3" cs=""
    if [ -f "${PWD}/Artefacts/features/kubernetes-tools/checksums.json" ]; then
      cs=$(jq -r --arg t "$tool" --arg v "$ver" --arg a "$arch" '.tools[$t].checksums[$v][$a] // empty' "${PWD}/Artefacts/features/kubernetes-tools/checksums.json" 2>/dev/null || true)
      [ -n "$cs" ] && { echo "$cs"; return 0; }
    fi
    if [ -f "${PWD}/Artefacts/checksums.json" ]; then
      cs=$(jq -r --arg t "$tool" --arg v "$ver" --arg a "$arch" '.tools[$t].checksums[$v][$a] // empty' "${PWD}/Artefacts/checksums.json" 2>/dev/null || true)
      [ -n "$cs" ] && { echo "$cs"; return 0; }
    fi
    if [ -f /tmp/checksums.json ]; then
      cs=$(jq -r --arg t "$tool" --arg v "$ver" --arg a "$arch" '.tools[$t].checksums[$v][$a] // empty' /tmp/checksums.json 2>/dev/null || true)
      [ -n "$cs" ] && { echo "$cs"; return 0; }
    fi
    echo ""
  }
  KUB_CHKSUM=$(resolve_checksum "kubectl" "${KUBECTL_VERSION}" "${ARCH}")
  install_and_link kubectl "${KUBECTL_VERSION}" "${KUBECTL_URL}" "${KUB_CHKSUM}" ""
fi

if [ -n "${HELM_VERSION}" ]; then
  echo "kubernetes-tools: installing helm ${HELM_VERSION} into toolcache"
  HELM_URL="https://get.helm.sh/helm-v${HELM_VERSION}-linux-${ARCH}.tar.gz"
  HELM_CHKSUM=$(resolve_checksum "helm" "${HELM_VERSION}" "${ARCH}")
  install_and_link helm "${HELM_VERSION}" "${HELM_URL}" "${HELM_CHKSUM}" "linux-${ARCH}/helm"
fi

if [ -n "${K9S_VERSION}" ]; then
  echo "kubernetes-tools: installing k9s ${K9S_VERSION} into toolcache"
  K9S_URL="https://github.com/derailed/k9s/releases/download/v${K9S_VERSION}/k9s_Linux_${ARCH}.tar.gz"
  K9S_CHKSUM=$(resolve_checksum "k9s" "${K9S_VERSION}" "${ARCH}")
  install_and_link k9s "${K9S_VERSION}" "${K9S_URL}" "${K9S_CHKSUM}" "k9s"
fi

if [ -n "${KUSTOMIZE_VERSION}" ]; then
  echo "kubernetes-tools: installing kustomize ${KUSTOMIZE_VERSION} into toolcache"
  KUST_URL="https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_${ARCH}.tar.gz"
  KUST_CHKSUM=$(resolve_checksum "kustomize" "${KUSTOMIZE_VERSION}" "${ARCH}")
  install_and_link kustomize "${KUSTOMIZE_VERSION}" "${KUST_URL}" "${KUST_CHKSUM}" "kustomize"
fi

if [ -n "${MINIKUBE_VERSION}" ]; then
  echo "kubernetes-tools: installing minikube ${MINIKUBE_VERSION} into toolcache"
  MINIKUBE_URL="https://github.com/kubernetes/minikube/releases/download/v${MINIKUBE_VERSION}/minikube-linux-${ARCH}"
  MINIKUBE_CHKSUM=$(resolve_checksum "minikube" "${MINIKUBE_VERSION}" "${ARCH}")
  install_and_link minikube "${MINIKUBE_VERSION}" "${MINIKUBE_URL}" "${MINIKUBE_CHKSUM}" ""
fi

chown -R ${NB_UID}:${NB_GID} "${LOCAL_BIN}" || true
echo "kubernetes-tools: installed binaries into ${LOCAL_BIN} (via /opt/toolcache)"
