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

echo "git-lfs: installing git-lfs"

if ! command -v git-lfs >/dev/null 2>&1; then
  # Prefer release binary install (works under qemu/emulation). Fall back to apt if helper missing.
  GIT_LFS_VERSION="3.4.1"
  if command -v download_github_release >/dev/null 2>&1; then
    echo "git-lfs: installing ${GIT_LFS_VERSION} via download_github_release helper"
    # git-lfs release naming: git-lfs-linux-amd64-v3.4.1.tar.gz
    download_github_release "git-lfs/git-lfs" "git-lfs" "${GIT_LFS_VERSION}" "/usr/local/bin" "git-lfs-linux-{arch}-v{version}.tar.gz" || true
  else
    if command -v apt_install >/dev/null 2>&1; then
      apt_install git-lfs || true
    else
      apt-get update && apt-get install -y --no-install-recommends git-lfs || true
    fi
    rm -rf /var/lib/apt/lists/* || true
  fi
fi

# Ensure git-lfs is initialized for the user
TMP_SCRIPT_GITLFS="/tmp/git-lfs-init-${NB_USER}.sh"
cat > "${TMP_SCRIPT_GITLFS}" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
git lfs install --skip-repo || true
BASH
chmod +x "${TMP_SCRIPT_GITLFS}" || true
su - ${NB_USER} -s /bin/bash -c "${TMP_SCRIPT_GITLFS}" || true
rm -f "${TMP_SCRIPT_GITLFS}" || true

echo "git-lfs: done"
