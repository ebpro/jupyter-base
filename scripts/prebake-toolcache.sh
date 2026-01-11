#!/usr/bin/env bash
set -euo pipefail

# Prebake Toolcache Builder
# Pre-downloads and caches common tools to /opt/toolcache for faster builds
# This script can be run during CI or as part of a multi-stage Docker build

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSIONS_FILE="${VERSIONS_FILE:-$ROOT_DIR/Artefacts/versions.json}"
OUTPUT_DIR="${OUTPUT_DIR:-/opt/toolcache}"

# Default tools to prebake (can be overridden via --tools)
DEFAULT_TOOLS="gh,kubectl,helm,k9s,kustomize,quarto,tilt,gitstatus,miniforge,node"
DEFAULT_ARCHS="amd64,arm64"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Prebake toolcache by downloading common tools specified in versions.json

Options:
  --tools TOOLS       Comma-separated list of tools to prebake (default: ${DEFAULT_TOOLS})
  --archs ARCHS       Comma-separated list of architectures (default: ${DEFAULT_ARCHS})
  --output DIR        Output directory for toolcache (default: ${OUTPUT_DIR})
  --versions FILE     Path to versions.json (default: ${VERSIONS_FILE})
  --help              Show this help message

Examples:
  # Prebake default tools
  $0

  # Prebake specific tools
  $0 --tools node,kubectl,helm

  # Custom output directory
  $0 --output /tmp/toolcache --tools gh,quarto

Environment Variables:
  VERSIONS_FILE       Path to versions.json file
  OUTPUT_DIR          Output directory for toolcache

EOF
  exit 0
}

# Parse arguments
TOOLS="${DEFAULT_TOOLS}"
ARCHS="${DEFAULT_ARCHS}"
while [[ $# -gt 0 ]]; do
  case $1 in
    --tools)
      TOOLS="$2"
      shift 2
      ;;
    --archs)
      ARCHS="$2"
      shift 2
      ;;
    --output)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --versions)
      VERSIONS_FILE="$2"
      shift 2
      ;;
    --help|-h)
      usage
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      ;;
  esac
done

echo "===================================================================="
echo "Prebaking Toolcache (Multi-Arch)"
echo "===================================================================="
echo "Versions file: ${VERSIONS_FILE}"
echo "Output directory: ${OUTPUT_DIR}"
echo "Architectures: ${ARCHS}"
echo "Tools: ${TOOLS}"
echo "====================================================================="

# Verify versions.json exists
if [ ! -f "${VERSIONS_FILE}" ]; then
  echo "❌ Error: versions.json not found at ${VERSIONS_FILE}" >&2
  exit 1
fi

# Verify jq is available
if ! command -v jq >/dev/null 2>&1; then
  echo "❌ Error: jq is required but not installed" >&2
  exit 1
fi

# Create output directory
mkdir -p "${OUTPUT_DIR}"

# Architecture detection and mapping
map_arch() {
  local arch="$1"
  case "$arch" in
    x86_64|X86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "$arch" ;;
  esac
}

HOST_ARCH=$(map_arch "$(uname -m)")
echo "Host architecture: ${HOST_ARCH}"
echo "Target architectures: ${ARCHS}"
echo ""

# Tool-specific download functions
download_gh() {
  local version="$1"
  local arch="$2"
  local url="https://github.com/cli/cli/releases/download/v${version}/gh_${version}_linux_${arch}.tar.gz"
  echo "📦 Downloading gh ${version} (${arch})..."
  local tmpdir="${OUTPUT_DIR}/gh/${version}/${arch}"
  mkdir -p "${tmpdir}"
  curl -fsSL "${url}" | tar -xz -C "${tmpdir}" --strip-components=1
  echo "   ✅ gh ${version} (${arch}) cached"
}

download_kubectl() {
  local version="$1"
  local arch="$2"
  local url="https://dl.k8s.io/release/v${version}/bin/linux/${arch}/kubectl"
  echo "📦 Downloading kubectl ${version} (${arch})..."
  local tmpdir="${OUTPUT_DIR}/kubectl/${version}/${arch}"
  mkdir -p "${tmpdir}/bin"
  curl -fsSL "${url}" -o "${tmpdir}/bin/kubectl"
  chmod +x "${tmpdir}/bin/kubectl"
  echo "   ✅ kubectl ${version} (${arch}) cached"
}

download_helm() {
  local version="$1"
  local arch="$2"
  local url="https://get.helm.sh/helm-v${version}-linux-${arch}.tar.gz"
  echo "📦 Downloading helm ${version} (${arch})..."
  local tmpdir="${OUTPUT_DIR}/helm/${version}/${arch}"
  mkdir -p "${tmpdir}"
  curl -fsSL "${url}" | tar -xz -C "${tmpdir}" --strip-components=1
  echo "   ✅ helm ${version} (${arch}) cached"
}

download_k9s() {
  local version="$1"
  local arch="$2"
  # k9s uses same arch naming
  local url="https://github.com/derailed/k9s/releases/download/v${version}/k9s_Linux_${arch}.tar.gz"
  echo "📦 Downloading k9s ${version} (${arch})..."
  local tmpdir="${OUTPUT_DIR}/k9s/${version}/${arch}"
  mkdir -p "${tmpdir}/bin"
  curl -fsSL "${url}" | tar -xz -C "${tmpdir}/bin" k9s
  chmod +x "${tmpdir}/bin/k9s"
  echo "   ✅ k9s ${version} (${arch}) cached"
}

download_kustomize() {
  local version="$1"
  local arch="$2"
  # kustomize uses same arch naming
  local url="https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${version}/kustomize_v${version}_linux_${arch}.tar.gz"
  echo "📦 Downloading kustomize ${version} (${arch})..."
  local tmpdir="${OUTPUT_DIR}/kustomize/${version}/${arch}"
  mkdir -p "${tmpdir}/bin"
  curl -fsSL "${url}" | tar -xz -C "${tmpdir}/bin"
  chmod +x "${tmpdir}/bin/kustomize"
  echo "   ✅ kustomize ${version} (${arch}) cached"
}

download_quarto() {
  local version="$1"
  local arch="$2"
  # Quarto uses same arch naming
  local url="https://github.com/quarto-dev/quarto-cli/releases/download/v${version}/quarto-${version}-linux-${arch}.tar.gz"
  echo "📦 Downloading quarto ${version} (${arch})..."
  local tmpdir="${OUTPUT_DIR}/quarto/${version}/${arch}"
  mkdir -p "${tmpdir}"
  curl -fsSL "${url}" | tar -xz -C "${tmpdir}" --strip-components=1
  echo "   ✅ quarto ${version} (${arch}) cached"
}

download_tilt() {
  local version="$1"
  local arch="$2"
  echo "📦 Downloading tilt ${version} (${arch})..."
  local tmpdir="${OUTPUT_DIR}/tilt/${version}/${arch}"
  mkdir -p "${tmpdir}/bin"

  # Try multiple common asset name patterns for different arch namings
  local tried=0
  local arch_candidates=("${arch}" "arm64" "aarch64" "x86_64" "amd64")
  for a in "${arch_candidates[@]}"; do
    local url="https://github.com/tilt-dev/tilt/releases/download/v${version}/tilt.${version}.linux.${a}.tar.gz"
    tried=$((tried + 1))
    if curl -fsSL "${url}" | tar -xz -C "${tmpdir}/bin" 2>/dev/null; then
      # Make sure the tilt binary is executable and located at tmpdir/bin/tilt
      if [ -f "${tmpdir}/bin/tilt" ]; then
        chmod +x "${tmpdir}/bin/tilt"
      else
        # Some archives may contain a directory; try to find the binary
        found=$(find "${tmpdir}/bin" -type f -name 'tilt' -print -quit || true)
        if [ -n "${found}" ]; then
          mv "$found" "${tmpdir}/bin/tilt" || true
          chmod +x "${tmpdir}/bin/tilt" || true
        fi
      fi
      echo "   ✅ tilt ${version} (${arch}) cached (using arch=${a})"
      return 0
    fi
  done

  echo "   ❌ tilt ${version} (${arch}) could not be downloaded with tried arch patterns (${arch_candidates[*]})" >&2
  return 1
}

download_miniforge() {
  local version="$1"
  local arch="$2"
  echo "📦 Downloading Miniforge ${version} (${arch})..."
  local tmpdir="${OUTPUT_DIR}/miniforge/${version}/${arch}"
  mkdir -p "${tmpdir}"
  # Map arch to Miniforge asset naming (e.g. Miniforge3-Linux-x86_64.sh)
  local osname="Linux"
  local arch_alias
  case "${arch}" in
    amd64) arch_alias="x86_64" ;;
    arm64) arch_alias="aarch64" ;;
    *) arch_alias="${arch}" ;;
  esac
  local installer_name="Miniforge3-${osname}-${arch_alias}.sh"
  local url
  if [ "${version}" = "latest" ]; then
    url="https://github.com/conda-forge/miniforge/releases/latest/download/${installer_name}"
  else
    url="https://github.com/conda-forge/miniforge/releases/download/${version}/${installer_name}"
  fi
  curl -fsSL "${url}" -o "${tmpdir}/${installer_name}"
  chmod +x "${tmpdir}/${installer_name}"
  echo "   ✅ Miniforge ${version} (${arch}) cached -> ${tmpdir}/${installer_name}"
}

download_gitstatus() {
  local version="$1"
  local arch="$2"
  # gitstatus uses different arch naming
  local gs_arch="${arch}"
  [ "${arch}" = "amd64" ] && gs_arch="x86_64"
  [ "${arch}" = "arm64" ] && gs_arch="aarch64"
  local url="https://github.com/romkatv/gitstatus/releases/download/v${version}/gitstatusd-linux-${gs_arch}.tar.gz"
  echo "📦 Downloading gitstatus ${version} (${arch})..."
  local tmpdir="${OUTPUT_DIR}/gitstatus/${version}/${arch}"
  mkdir -p "${tmpdir}/bin"
  curl -fsSL "${url}" | tar -xz -C "${tmpdir}/bin"
  chmod +x "${tmpdir}/bin/gitstatusd"
  echo "   ✅ gitstatus ${version} (${arch}) cached"
}

download_node() {
  local version="$1"
  local arch="$2"
  # Node.js uses different arch naming
  local node_arch="${arch}"
  [ "${arch}" = "amd64" ] && node_arch="x64"
  [ "${arch}" = "arm64" ] && node_arch="arm64"
  local url="https://nodejs.org/dist/v${version}/node-v${version}-linux-${node_arch}.tar.xz"
  echo "📦 Downloading node ${version} (${arch})..."
  local tmpdir="${OUTPUT_DIR}/node/${version}/${arch}"
  mkdir -p "${tmpdir}"
  curl -fsSL "${url}" | tar -xJ -C "${tmpdir}" --strip-components=1
  echo "   ✅ node ${version} (${arch}) cached"
}

# Process each tool
IFS=',' read -ra TOOL_ARRAY <<< "${TOOLS}"
TOTAL=${#TOOL_ARRAY[@]}
CURRENT=0
SUCCEEDED=0
FAILED=0

for tool in "${TOOL_ARRAY[@]}"; do
  tool=$(echo "$tool" | xargs)  # trim whitespace
  CURRENT=$((CURRENT + 1))

  echo ""
  echo "[${CURRENT}/${TOTAL}] Processing: ${tool}"
  echo "--------------------------------------------------------------------"

  # Get version from versions.json
  version=$(jq -r ".tools[\"${tool}\"] // empty" "${VERSIONS_FILE}" 2>/dev/null || true)

  if [ -z "$version" ] || [ "$version" = "null" ]; then
    echo "⚠️  Warning: Version not found in versions.json for ${tool}, skipping"
    FAILED=$((FAILED + 1))
    continue
  fi

  echo "Version: ${version}"

  # Check if already cached
  if [ -d "${OUTPUT_DIR}/${tool}/${version}" ]; then
    echo "✓ Already cached, skipping download"
    SUCCEEDED=$((SUCCEEDED + 1))
    continue
  fi

  # Download based on tool type
  case "$tool" in
    gh)
      download_gh "$version" && SUCCEEDED=$((SUCCEEDED + 1)) || FAILED=$((FAILED + 1))
      ;;
    kubectl)
      download_kubectl "$version" && SUCCEEDED=$((SUCCEEDED + 1)) || FAILED=$((FAILED + 1))
      ;;
    helm)
      download_helm "$version" && SUCCEEDED=$((SUCCEEDED + 1)) || FAILED=$((FAILED + 1))
      ;;
    k9s)
      download_k9s "$version" && SUCCEEDED=$((SUCCEEDED + 1)) || FAILED=$((FAILED + 1))
      ;;
    kustomize)
      download_kustomize "$version" && SUCCEEDED=$((SUCCEEDED + 1)) || FAILED=$((FAILED + 1))
      ;;
    quarto)
      download_quarto "$version" && SUCCEEDED=$((SUCCEEDED + 1)) || FAILED=$((FAILED + 1))
      ;;
    tilt)
      download_tilt "$version" && SUCCEEDED=$((SUCCEEDED + 1)) || FAILED=$((FAILED + 1))
      ;;
    miniforge)
      download_miniforge "$version" && SUCCEEDED=$((SUCCEEDED + 1)) || FAILED=$((FAILED + 1))
      ;;
    gitstatus)
      download_gitstatus "$version" && SUCCEEDED=$((SUCCEEDED + 1)) || FAILED=$((FAILED + 1))
      ;;
    node)
      download_node "$version" && SUCCEEDED=$((SUCCEEDED + 1)) || FAILED=$((FAILED + 1))
      ;;
    *)
      echo "⚠️  Warning: Unknown tool ${tool}, skipping"
      FAILED=$((FAILED + 1))
      ;;
  esac
done

echo ""
echo "===================================================================="
echo "Prebake Summary"
echo "===================================================================="
echo "Total tools: ${TOTAL}"
echo "Succeeded: ${SUCCEEDED}"
echo "Failed: ${FAILED}"
echo "Cache location: ${OUTPUT_DIR}"
echo ""

# Calculate cache size
if command -v du >/dev/null 2>&1; then
  cache_size=$(du -sh "${OUTPUT_DIR}" 2>/dev/null | cut -f1 || echo "unknown")
  echo "Total cache size: ${cache_size}"
fi

echo ""
if [ ${FAILED} -gt 0 ]; then
  echo "⚠️  Some tools failed to download. Review the output above for details."
  exit 1
else
  echo "✅ All tools successfully prebaked!"
  echo ""
  echo "Next steps:"
  echo "1. Use this toolcache in Dockerfile:"
  echo "   COPY --from=toolcache-builder ${OUTPUT_DIR} ${OUTPUT_DIR}"
  echo ""
  echo "2. Or mount as cache:"
  echo "   RUN --mount=type=cache,target=${OUTPUT_DIR},sharing=locked ..."
fi
