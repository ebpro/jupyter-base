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

resolve_version() {
  local tool="$1" v=""
  # Prefer centralized helper when available
  if command -v fh_resolve_version >/dev/null 2>&1; then
    local hv
    hv=$(fh_resolve_version "$tool" || true)
    if [ -n "$hv" ]; then
      echo "$hv"
      return 0
    fi
  fi

  if [ -f "${PWD}/artefacts/${tool}/versions.json" ]; then
    v=$(jq -r --arg t "$tool" '.tools[$t] // empty' "${PWD}/artefacts/${tool}/versions.json" 2>/dev/null || true)
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

echo "prompt-helpers: preparing to install gitstatusd ${GITSTATUS_VERSION}"

# Before attempting the download, probe the upstream release URL that would be used
# and skip installation on platforms where the artifact is not published to avoid
# hard failures during multi-arch builds.
probe_arch=$(uname -m)
case "$probe_arch" in
  x86_64) probe_token="amd64" ;;
  aarch64) probe_token="aarch64" ;;
  arm64) probe_token="aarch64" ;;
  *) probe_token="$probe_arch" ;;
esac
probe_url="https://github.com/romkatv/gitstatus/releases/download/v${GITSTATUS_VERSION}/gitstatusd-linux-${probe_token}.tar.gz"

if curl -sfI "$probe_url" >/dev/null 2>&1; then
  echo "prompt-helpers: found upstream artifact for ${probe_token}, proceeding"
  # Use download_github_release helper to download and extract gitstatusd
  download_github_release \
    "romkatv/gitstatus" \
    "gitstatusd" \
    "${GITSTATUS_VERSION}" \
    "${HOME_DIR}/.cache/gitstatus" \
    "gitstatusd-linux-{arch}.tar.gz" \
    "true"
else
  echo "prompt-helpers: ⚠️ gitstatus upstream artifact not available for platform token '${probe_token}' (URL: ${probe_url})"
  echo "prompt-helpers: available upstream URLs include (examples):"
  echo "  https://github.com/romkatv/gitstatus/releases/download/v${GITSTATUS_VERSION}/gitstatusd-linux-aarch64.tar.gz"
  echo "  https://github.com/romkatv/gitstatus/releases/download/v${GITSTATUS_VERSION}/gitstatusd-darwin-x86_64.tar.gz"
  echo "prompt-helpers: skipping gitstatusd installation on this platform to avoid 404 failures"
fi

# Set ownership
chown -R "${NB_UID}":"${NB_GID}" "${HOME_DIR}/.cache/gitstatus" || true

echo "prompt-helpers: done"

# If the helper didn't place an executable at the expected path, try a resilient
# fallback: search cached archives, list their contents and extract any matching
# gitstatus/gitstatusd binary into the cache location.
TARGET_DIR="${HOME_DIR}/.cache/gitstatus"
TARGET_BIN="${TARGET_DIR}/gitstatusd"
mkdir -p "${TARGET_DIR}" || true
if [ ! -x "${TARGET_BIN}" ]; then
  echo "prompt-helpers: fallback - gitstatusd not found, searching archives"
  candidates=()
  # Look in typical toolcache locations and user cache
  while IFS= read -r f; do candidates+=("$f"); done < <(find /opt/toolcache -type f -name '*gitstatus*.tar*' 2>/dev/null || true)
  while IFS= read -r f; do candidates+=("$f"); done < <(find "${TARGET_DIR}" -type f -name '*gitstatus*.tar*' 2>/dev/null || true)

  for a in "${candidates[@]}"; do
    [ -f "$a" ] || continue
    echo "prompt-helpers: inspecting archive $a"
    # list entries and attempt to find a file named gitstatusd or gitstatus
    entry=$(tar -tzf "$a" 2>/dev/null | awk -F"/" '/gitstatusd$|gitstatus$/{print; exit}') || true
    if [ -n "$entry" ]; then
      echo "prompt-helpers: extracting $entry from $a"
      # extract to a temp dir then move into place
      tmpdir=$(mktemp -d)
      tar -xzf "$a" -C "$tmpdir" "$entry" 2>/dev/null || true
      src="$tmpdir/$entry"
      if [ -f "$src" ]; then
        mv "$src" "$TARGET_BIN" 2>/dev/null || cp -a "$src" "$TARGET_BIN" 2>/dev/null || true
        chmod +x "$TARGET_BIN" 2>/dev/null || true
        rm -rf "$tmpdir" || true
        echo "prompt-helpers: installed gitstatusd to $TARGET_BIN"
        break
      fi
      rm -rf "$tmpdir" || true
    fi
  done
  if [ ! -x "$TARGET_BIN" ]; then
    echo "prompt-helpers: ❌ gitstatusd still not found after fallback"
  fi
fi
