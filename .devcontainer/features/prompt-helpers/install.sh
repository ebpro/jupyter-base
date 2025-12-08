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

resolve_version() {
  local tool="$1" v=""
  if [ -f "${PWD}/Artefacts/features/${tool}/versions.json" ]; then
    v=$(jq -r --arg t "$tool" '.tools[$t] // empty' "${PWD}/Artefacts/features/${tool}/versions.json" 2>/dev/null || true)
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

GITSTATUS_VERSION=$(resolve_version "gitstatus")
if [ -z "$GITSTATUS_VERSION" ]; then
  echo "prompt-helpers: gitstatus version not provided, skipping"
  exit 0
fi

# Normalize architecture and select download-friendly alias
if [ -f "${PWD}/scripts/arch.sh" ]; then
  # shellcheck source=/dev/null
  source "${PWD}/scripts/arch.sh"
  ARCH_CANON=$(arch_map "${TARGETPLATFORM:-$(uname -m)}")
  # prefer asset-friendly names: amd64 -> x86_64, arm64 -> aarch64
  case "$ARCH_CANON" in
    amd64) DL_ARCH="x86_64" ;;
    arm64) DL_ARCH="aarch64" ;;
    *) DL_ARCH="$ARCH_CANON" ;;
  esac
else
  DL_ARCH=$(case "$(uname -m)" in x86_64|X86_64) echo "x86_64" ;; aarch64) echo "aarch64" ;; *) echo "x86_64" ;; esac)
fi

echo "prompt-helpers: installing gitstatusd ${GITSTATUS_VERSION}"
GITSTATUS_URL="https://github.com/romkatv/gitstatus/releases/download/v${GITSTATUS_VERSION}/gitstatusd-linux-${DL_ARCH}.tar.gz"

resolve_checksum() {
  local tool="$1" ver="$2" arch="$3" cs=""
  if [ -f "${PWD}/Artefacts/features/${tool}/checksums.json" ]; then
    cs=$(jq -r --arg t "$tool" --arg v "$ver" --arg a "$arch" '.tools[$t].checksums[$v][$a] // empty' "${PWD}/Artefacts/features/${tool}/checksums.json" 2>/dev/null || true)
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

# Resolve checksum from per-feature, central, or /tmp
CHKSUM=$(resolve_checksum "gitstatus" "${GITSTATUS_VERSION}" "${ARCH}")

# Try toolcache-get (with checksum) to avoid repeated downloads and extraction
if command -v toolcache-get >/dev/null 2>&1; then
  # First, prefer a local per-arch pre-extracted artefact under the repo (fast, deterministic)
  LOCAL_PREFIX_BASE="${PWD}/Artefacts/features/prompt-helpers/toolcache/gitstatus/${GITSTATUS_VERSION}"
  LOCAL_PREFIX_ARCH="${LOCAL_PREFIX_BASE}/${ARCH}"
  if [ -d "$LOCAL_PREFIX_ARCH" ] && [ -n "$(ls -A "$LOCAL_PREFIX_ARCH" 2>/dev/null || true)" ]; then
    echo "prompt-helpers: local artefact found at ${LOCAL_PREFIX_ARCH} (arch-specific cache hit)"
    mkdir -p "${HOME_DIR}/.cache/gitstatus"
    cp -a "$LOCAL_PREFIX_ARCH/"* "${HOME_DIR}/.cache/gitstatus/" || true
    chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/.cache/gitstatus" || true
    echo "prompt-helpers: installed gitstatusd from local artefacts (${ARCH})"
    echo "prompt-helpers: done"
    exit 0
  fi
  # Fallback to generic version directory (host-specific but may be used across arches)
  if [ -d "$LOCAL_PREFIX_BASE" ] && [ -n "$(ls -A "$LOCAL_PREFIX_BASE" 2>/dev/null || true)" ]; then
    echo "prompt-helpers: local artefact found at ${LOCAL_PREFIX_BASE} (generic cache hit)"
    mkdir -p "${HOME_DIR}/.cache/gitstatus"
    cp -a "$LOCAL_PREFIX_BASE/"* "${HOME_DIR}/.cache/gitstatus/" || true
    chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/.cache/gitstatus" || true
    echo "prompt-helpers: installed gitstatusd from local artefacts"
    echo "prompt-helpers: done"
    exit 0
  else
    echo "prompt-helpers: no local artefact at ${LOCAL_PREFIX_BASE} (cache miss)"
  fi

  # Try toolcache-get next to reuse cached downloads (shared /opt/toolcache)
  TOOLCACHE_PREFIX=$(toolcache-get "gitstatus" "${GITSTATUS_VERSION}" "${GITSTATUS_URL}" "${CHKSUM:-}" "gitstatusd-linux-${ARCH}.tar.gz" 2>/dev/null || true)
  if [ -n "$TOOLCACHE_PREFIX" ] && [ -d "$TOOLCACHE_PREFIX" ] && [ -n "$(ls -A "$TOOLCACHE_PREFIX" 2>/dev/null || true)" ]; then
    echo "prompt-helpers: toolcache-get returned ${TOOLCACHE_PREFIX} (cache hit)"
    mkdir -p "${HOME_DIR}/.cache/gitstatus"
    cp -a "$TOOLCACHE_PREFIX/"* "${HOME_DIR}/.cache/gitstatus/" || true
    chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/.cache/gitstatus" || true
    echo "prompt-helpers: installed gitstatusd from toolcache at ${TOOLCACHE_PREFIX}"
    echo "prompt-helpers: done"
    exit 0
  else
    echo "prompt-helpers: toolcache-get did not have gitstatus (cache miss), falling back to download"
  fi
fi

download_with_backoff() {
  local url="$1" dest="$2"
  local max_attempts=6
  local attempt=0
  local backoff=2
  local headers

  # If a GitHub token is available, include it to increase API/rate limits
  local auth_header
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    auth_header=( -H "Authorization: Bearer ${GITHUB_TOKEN}" )
  else
    auth_header=()
  fi

  while [ $attempt -lt $max_attempts ]; do
    attempt=$((attempt+1))
    echo "prompt-helpers: download attempt ${attempt}/${max_attempts} for ${url}"
    rm -f "$dest" || true
    headers=$(mktemp)

    # Use curl to follow redirects, store headers for rate-limit inspection
    if curl -sS -L -D "$headers" "${auth_header[@]}" -o "$dest" --connect-timeout 15 --max-time 300 "$url"; then
      status=$(awk 'END{for(i=NR;i>0;i--){ if($0 ~ /^HTTP/){print $2; exit}}}' "$headers") || status=200
      [ -z "$status" ] && status=200
    else
      status=$(awk 'END{for(i=NR;i>0;i--){ if($0 ~ /^HTTP/){print $2; exit}}}' "$headers") || status=0
    fi

    if [ "$status" -ge 200 ] && [ "$status" -lt 300 ] && [ -s "$dest" ]; then
      echo "prompt-helpers: received HTTP ${status}, downloaded ${dest}"
      rm -f "$headers" || true
      return 0
    fi

    # Handle rate-limit responses (429/403)
    if [ "$status" -eq 429 ] || [ "$status" -eq 403 ]; then
      retry_after=$(awk '/^Retry-After:/ {print $2}' "$headers" | tr -d '\r' || true)
      if [ -z "$retry_after" ]; then
        reset=$(awk -F: '/^X-RateLimit-Reset/ {print $2}' "$headers" | tr -d ' \r' || true)
        if [ -n "$reset" ]; then
          now=$(date +%s)
          wait_for=$(( reset - now ))
          [ $wait_for -lt 0 ] && wait_for=10
          retry_after=$wait_for
        fi
      fi
      if [ -n "$retry_after" ]; then
        echo "prompt-helpers: rate limited (HTTP ${status}), sleeping for ${retry_after}s before retry"
        sleep $retry_after
        rm -f "$headers" || true
        continue
      fi
    fi

    echo "prompt-helpers: download HTTP ${status}, retrying after ${backoff}s"
    sleep $backoff
    backoff=$((backoff * 2))
    rm -f "$headers" || true
  done

  return 1
}

# perform download with backoff
TMP_FILE=/tmp/gitstatusd.tar.gz
if ! download_with_backoff "${GITSTATUS_URL}" "$TMP_FILE"; then
  echo "prompt-helpers: failed to download gitstatusd after retries" >&2
  exit 1
fi

# verify checksum if present
if [ -n "$CHKSUM" ]; then
  if command -v verify-artifact >/dev/null 2>&1; then
    if ! verify-artifact "$CHKSUM" "$TMP_FILE"; then
      echo "prompt-helpers: checksum verification failed" >&2
      exit 1
    fi
  else
    echo "$CHKSUM  $TMP_FILE" > /tmp/gitstatusd.sha256 && sha256sum -c /tmp/gitstatusd.sha256
    rm -f /tmp/gitstatusd.sha256 || true
  fi
fi

# Ensure tar integrity
if ! tar -tzf "$TMP_FILE" >/dev/null 2>&1; then
  echo "prompt-helpers: downloaded archive is corrupt" >&2
  rm -f "$TMP_FILE" || true
  exit 1
fi

mkdir -p "${HOME_DIR}/.cache/gitstatus"
tar -C "${HOME_DIR}/.cache/gitstatus" -zx -f "$TMP_FILE"
rm -f "$TMP_FILE" || true
chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/.cache/gitstatus" || true

echo "prompt-helpers: done"
