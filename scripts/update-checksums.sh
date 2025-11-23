#!/usr/bin/env bash
set -euo pipefail

# Script to download binaries for pinned versions and compute SHA256 checksums
# It updates `Artefacts/checksums.json` with entries like:
# { "quarto": { "1.8.24": { "amd64": "<sha256>" } } }

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
CENTRAL_FILE="$REPO_ROOT/Artefacts/checksums.json"
CHECKSUMS_FILE="$CENTRAL_FILE"
VERSIONS_FILE="$REPO_ROOT/Artefacts/versions.json"
TMPDIR=$(mktemp -d)
ARCH_LOCAL=$(uname -m)

arch_map() {
  case "$1" in
    x86_64|X86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) echo amd64 ;;
  esac
}

# Return aliases for common arch names (used when release assets use different naming)
arch_aliases() {
  case "$1" in
    amd64) echo "amd64 x86_64" ;;
    arm64) echo "arm64 aarch64 armv8" ;;
    *) echo "$1" ;;
  esac
}

# Default ARCHS: if ARCHS env var provided use it (space-separated), else use local arch
if [ -n "${ARCHS:-}" ]; then
  read -r -a ARCHS_ARR <<< "$ARCHS"
else
  ARCHS_ARR=("$(arch_map "$ARCH_LOCAL")")
fi

get_version() {
  jq -r --arg k "$1" '.tools[$k] // empty' "$VERSIONS_FILE"
}

# Return 0 if tool is locked in the centralized checksums file
is_locked() {
  local tool=$1
  if [ ! -f "$CHECKSUMS_FILE" ]; then
    return 1
  fi
  local v
  v=$(jq -r --arg t "$tool" '.tools[$t].locked // false' "$CHECKSUMS_FILE" 2>/dev/null || echo false)
  [ "$v" = "true" ] && return 0 || return 1
}

update_checksums() {
  local tool=$1 ver=$2 arch=$3 sha=$4
  # Respect per-tool lock unless FORCE_UPDATE=1
  if [ "${FORCE_UPDATE:-}" != "1" ] && is_locked "$tool"; then
    >&2 echo "Skipping update for $tool (locked in $CHECKSUMS_FILE)"
    return 0
  fi
  # Update checksums.json under .tools[tool].checksums[version][arch]
  jq --arg t "$tool" --arg v "$ver" --arg a "$arch" --arg s "$sha" \
    '(.tools[$t] //= {}) | (.tools[$t].checksums //= {}) | (.tools[$t].checksums[$v] //= {}) | .tools[$t].checksums[$v][$a] = $s' \
    "$CHECKSUMS_FILE" > "$CHECKSUMS_FILE.tmp" && mv "$CHECKSUMS_FILE.tmp" "$CHECKSUMS_FILE"
}

download_and_hash() {
  local url=$1 dest=$2
  >&2 echo "Trying $url"
  if curl -fsSL -o "$dest" "$url"; then
    sha256sum "$dest" | awk '{print $1}'
  else
    return 1
  fi
}

# Find a release asset download URL from GitHub releases by tag.
# Params: owner repo tag pattern
find_github_asset() {
  local owner=$1 repo=$2 tag=$3 pattern=$4
  local api url
  api="https://api.github.com/repos/${owner}/${repo}/releases/tags/v${tag}"
  # Try tag endpoint first
  if curl -fsSL "$api" >/tmp/release.json 2>/dev/null; then
    url=$(jq -r --arg p "$pattern" '.assets[] | select(.name|test($p; "i")) | .browser_download_url' /tmp/release.json 2>/dev/null | head -n1 || true)
    if [ -n "$url" ]; then
      echo "$url"
      rm -f /tmp/release.json
      return 0
    fi
  fi
  rm -f /tmp/release.json || true
  # Fallback to latest
  api="https://api.github.com/repos/${owner}/${repo}/releases/latest"
  if curl -fsSL "$api" >/tmp/release.json 2>/dev/null; then
    url=$(jq -r --arg p "$pattern" '.assets[] | select(.name|test($p; "i")) | .browser_download_url' /tmp/release.json 2>/dev/null | head -n1 || true)
    if [ -n "$url" ]; then
      echo "$url"
      rm -f /tmp/release.json
      return 0
    fi
  fi
  rm -f /tmp/release.json || true
  return 1
}

echo "Using architectures: ${ARCHS_ARR[*]}"

# Tools to check: kubectl, helm, k9s, kustomize, gitstatus, quarto

KUBECTL_VER=$(get_version kubectl)
if [ -n "$KUBECTL_VER" ] && [ "$KUBECTL_VER" != "null" ]; then
  for ARCH in "${ARCHS_ARR[@]}"; do
    read -r -a ALIASES <<< "$(arch_aliases "$ARCH")"
    for a in "${ALIASES[@]}"; do
      url="https://dl.k8s.io/release/v${KUBECTL_VER}/bin/linux/${a}/kubectl"
      dest="$TMPDIR/kubectl-${ARCH}"
      if sha=$(download_and_hash "$url" "$dest"); then
        echo "kubectl $KUBECTL_VER $a -> $sha"
        update_checksums kubectl "$KUBECTL_VER" "$ARCH" "$sha"
        break
      fi
    done
  done
fi

HELM_VER=$(get_version helm)
if [ -n "$HELM_VER" ] && [ "$HELM_VER" != "null" ]; then
  candidates=(
    "https://get.helm.sh/helm-v${HELM_VER}-linux-{arch}.tar.gz"
    "https://github.com/helm/helm/releases/download/v${HELM_VER}/helm-v${HELM_VER}-linux-{arch}.tar.gz"
  )
  for ARCH in "${ARCHS_ARR[@]}"; do
    read -r -a ALIASES <<< "$(arch_aliases "$ARCH")"
    for url in "${candidates[@]}"; do
      for a in "${ALIASES[@]}"; do
        dest="$TMPDIR/helm-${ARCH}.tar.gz"
        url_arch=${url//\{arch\}/$a}
        if sha=$(download_and_hash "$url_arch" "$dest"); then
          echo "helm $HELM_VER $a -> $sha"
          update_checksums helm "$HELM_VER" "$ARCH" "$sha"
          continue 3
        fi
      done
    done
    # fallback: try GitHub assets via API (match any alias)
    alias_regex=$(IFS='|'; echo "${ALIASES[*]}")
    gh_url=$(find_github_asset "helm" "helm" "$HELM_VER" "linux.*(${alias_regex})|(${alias_regex}).*linux") || true
    if [ -n "$gh_url" ]; then
      dest="$TMPDIR/helm-${ARCH}.tar.gz"
      if sha=$(download_and_hash "$gh_url" "$dest"); then
        echo "helm $HELM_VER $ARCH -> $sha (from GitHub assets)"
        update_checksums helm "$HELM_VER" "$ARCH" "$sha"
      fi
    fi
  done
fi

K9S_VER=$(get_version k9s)
if [ -n "$K9S_VER" ] && [ "$K9S_VER" != "null" ]; then
  candidates=(
    "https://github.com/derailed/k9s/releases/download/v${K9S_VER}/k9s_Linux_{arch}.tar.gz"
  )
  for ARCH in "${ARCHS_ARR[@]}"; do
    read -r -a ALIASES <<< "$(arch_aliases "$ARCH")"
    for url in "${candidates[@]}"; do
      for a in "${ALIASES[@]}"; do
        url_arch=${url//\{arch\}/$a}
        dest="$TMPDIR/k9s-${ARCH}.tar.gz"
        if sha=$(download_and_hash "$url_arch" "$dest"); then
          echo "k9s $K9S_VER $a -> $sha"
          update_checksums k9s "$K9S_VER" "$ARCH" "$sha"
          continue 3
        fi
      done
    done
    # fallback: query GitHub release assets for k9s (match any alias)
    alias_regex=$(IFS='|'; echo "${ALIASES[*]}")
    gh_url=$(find_github_asset "derailed" "k9s" "$K9S_VER" "(?i)k9s.*(${alias_regex}).*\\.(tar.gz|zip|tgz)$") || true
    if [ -n "$gh_url" ]; then
      dest="$TMPDIR/k9s-${ARCH}.tar.gz"
      if sha=$(download_and_hash "$gh_url" "$dest"); then
        echo "k9s $K9S_VER $ARCH -> $sha (from GitHub assets)"
        update_checksums k9s "$K9S_VER" "$ARCH" "$sha"
      fi
    fi
  done
fi

KUSTOMIZE_VER=$(get_version kustomize)
if [ -n "$KUSTOMIZE_VER" ] && [ "$KUSTOMIZE_VER" != "null" ]; then
  candidates=(
    "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VER}/kustomize_v${KUSTOMIZE_VER}_linux_{arch}.tar.gz"
  )
  for ARCH in "${ARCHS_ARR[@]}"; do
    read -r -a ALIASES <<< "$(arch_aliases "$ARCH")"
    for url in "${candidates[@]}"; do
      for a in "${ALIASES[@]}"; do
        dest="$TMPDIR/kustomize-${ARCH}.tar.gz"
        url_arch=${url//\{arch\}/$a}
        if sha=$(download_and_hash "$url_arch" "$dest"); then
          echo "kustomize $KUSTOMIZE_VER $a -> $sha"
          update_checksums kustomize "$KUSTOMIZE_VER" "$ARCH" "$sha"
          continue 3
        fi
      done
    done
    # fallback: query GitHub release assets
    alias_regex=$(IFS='|'; echo "${ALIASES[*]}")
    gh_url=$(find_github_asset "kubernetes-sigs" "kustomize" "$KUSTOMIZE_VER" "kustomize.*(${alias_regex}).*\\.(tar.gz|zip|tgz)") || true
    if [ -n "$gh_url" ]; then
      dest="$TMPDIR/kustomize-${ARCH}.tar.gz"
      if sha=$(download_and_hash "$gh_url" "$dest"); then
        echo "kustomize $KUSTOMIZE_VER $ARCH -> $sha (from GitHub assets)"
        update_checksums kustomize "$KUSTOMIZE_VER" "$ARCH" "$sha"
      fi
    fi
  done
fi

GITSTATUS_VER=$(get_version gitstatus)
if [ -n "$GITSTATUS_VER" ] && [ "$GITSTATUS_VER" != "null" ]; then
  for ARCH in "${ARCHS_ARR[@]}"; do
    read -r -a ALIASES <<< "$(arch_aliases "$ARCH")"
    for a in "${ALIASES[@]}"; do
      url="https://github.com/romkatv/gitstatus/releases/download/v${GITSTATUS_VER}/gitstatusd-linux-${a}.tar.gz"
      dest="$TMPDIR/gitstatusd-${ARCH}.tar.gz"
      if sha=$(download_and_hash "$url" "$dest"); then
        echo "gitstatus $GITSTATUS_VER $a -> $sha"
        update_checksums gitstatus "$GITSTATUS_VER" "$ARCH" "$sha"
        break
      fi
    done
  done
fi

QUARTO_VER=$(get_version quarto)
if [ -n "$QUARTO_VER" ] && [ "$QUARTO_VER" != "null" ]; then
  for ARCH in "${ARCHS_ARR[@]}"; do
    read -r -a ALIASES <<< "$(arch_aliases "$ARCH")"
    for a in "${ALIASES[@]}"; do
      url="https://github.com/quarto-dev/quarto-cli/releases/download/v${QUARTO_VER}/quarto-${QUARTO_VER}-linux-${a}.tar.gz"
      dest="$TMPDIR/quarto-${ARCH}.tar.gz"
      if sha=$(download_and_hash "$url" "$dest"); then
        echo "quarto $QUARTO_VER $a -> $sha"
        update_checksums quarto "$QUARTO_VER" "$ARCH" "$sha"
        break
      fi
    done
  done
fi

# minikube: raw binary for linux
MINIKUBE_VER=$(get_version minikube)
if [ -n "$MINIKUBE_VER" ] && [ "$MINIKUBE_VER" != "null" ]; then
  for ARCH in "${ARCHS_ARR[@]}"; do
    read -r -a ALIASES <<< "$(arch_aliases "$ARCH")"
    for a in "${ALIASES[@]}"; do
      url="https://github.com/kubernetes/minikube/releases/download/v${MINIKUBE_VER}/minikube-linux-${a}"
      dest="$TMPDIR/minikube-${ARCH}"
      if sha=$(download_and_hash "$url" "$dest"); then
        echo "minikube $MINIKUBE_VER $a -> $sha"
        update_checksums minikube "$MINIKUBE_VER" "$ARCH" "$sha"
        break
      fi
    done
  done
fi

# GitHub CLI (gh) tarball
GH_VER=$(get_version gh)
if [ -n "$GH_VER" ] && [ "$GH_VER" != "null" ]; then
  for ARCH in "${ARCHS_ARR[@]}"; do
    read -r -a ALIASES <<< "$(arch_aliases "$ARCH")"
    for a in "${ALIASES[@]}"; do
      url="https://github.com/cli/cli/releases/download/v${GH_VER}/gh_${GH_VER}_linux_${a}.tar.gz"
      dest="$TMPDIR/gh-${ARCH}.tar.gz"
      if sha=$(download_and_hash "$url" "$dest"); then
        echo "gh $GH_VER $a -> $sha"
        update_checksums gh "$GH_VER" "$ARCH" "$sha"
        continue 2
      fi
    done
    # fallback: find via GitHub API
    alias_regex=$(IFS='|'; echo "${ALIASES[*]}")
    gh_url=$(find_github_asset "cli" "cli" "$GH_VER" "gh_.*(${alias_regex}).*\\.(tar.gz|zip|deb)") || true
    if [ -n "$gh_url" ]; then
      if sha=$(download_and_hash "$gh_url" "$dest"); then
        echo "gh $GH_VER $ARCH -> $sha (from GitHub assets)"
        update_checksums gh "$GH_VER" "$ARCH" "$sha"
      fi
    fi
  done
fi

echo "Checksums updated in $CHECKSUMS_FILE"
rm -rf "$TMPDIR"
