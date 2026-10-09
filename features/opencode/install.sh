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

# OpenCode Installation
# - Installs the OpenCode AI coding agent as a global npm package (version-pinned).
# - When SSH_PRIVATE_KEY is provided at build time, clones the private
#   ebpro/opencode-config repository and copies it into ~/.config/opencode/.
#
# LLM credentials (VLLM_API_KEY, LIS_LAB_API_KEY) are NOT written by this script:
# the bundled configuration is credential-agnostic and reads them from the
# environment at container start (values provided by the caller).

NB_USER="${NB_USER:-jovyan}"
NB_UID="${NB_UID:-1001}"
NB_GID="${NB_GID:-1001}"
HOME_DIR="/home/${NB_USER}"

OPENCODE_REPO="${OPENCODE_CONFIG_REPO:-git@github.com:ebpro/opencode-config.git}"
DEFAULT_OPENCODE_VERSION="1.18.29"

echo "===================================================================="
echo "Feature: opencode"
echo "===================================================================="

# Ensure per-user local/cache/config dirs exist (helper when available, fallback otherwise)
if command -v fh_ensure_user_dirs >/dev/null 2>&1; then
  fh_ensure_user_dirs "${NB_USER}" "${NB_UID}" "${NB_GID}" || true
else
  mkdir -p "${HOME_DIR}/.local/bin" "${HOME_DIR}/.config" >/dev/null 2>&1 || true
  chown -R "${NB_UID}:${NB_GID}" "${HOME_DIR}/.local" "${HOME_DIR}/.config" >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# 1. Verify Node.js / npm (opencode is installed as a global npm package)
# ---------------------------------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  echo "❌ Node.js not found. Please install the 'node' feature first."
  exit 1
fi
if ! command -v npm >/dev/null 2>&1; then
  echo "❌ npm not found. Please install the 'node' feature first."
  exit 1
fi
echo "Node.js: $(node --version)"
echo "npm: $(npm --version)"

# ---------------------------------------------------------------------------
# 2. Resolve the opencode version (central versions.json, fallback to pinned)
# ---------------------------------------------------------------------------
OPENCODE_VERSION="${VERSION:-${DEFAULT_OPENCODE_VERSION}}"
if command -v fh_resolve_version >/dev/null 2>&1; then
  RESOLVED="$(fh_resolve_version "opencode" 2>/dev/null || true)"
  if [ -n "${RESOLVED}" ] && [ "${RESOLVED}" != "latest" ]; then
    OPENCODE_VERSION="${RESOLVED}"
  fi
fi
echo "opencode version to install: ${OPENCODE_VERSION}"

# ---------------------------------------------------------------------------
# 3. Install the opencode binary globally (idempotent)
# ---------------------------------------------------------------------------
echo "📦 Installing opencode-ai@${OPENCODE_VERSION} globally via npm..."
npm install -g "opencode-ai@${OPENCODE_VERSION}"

if command -v fh_write_history >/dev/null 2>&1; then
  fh_write_history "{\"feature\":\"opencode\",\"resolved_version\":\"${OPENCODE_VERSION}\"}" || true
fi

# ---------------------------------------------------------------------------
# 4. Deploy configuration (private repo) when SSH_PRIVATE_KEY is provided
# ---------------------------------------------------------------------------
CONFIG_DIR="${HOME_DIR}/.config/opencode"
mkdir -p "${CONFIG_DIR}"
chown -R "${NB_UID}:${NB_GID}" "${HOME_DIR}/.config" || true

if [ -n "${SSH_PRIVATE_KEY:-}" ]; then
  echo "🔐 SSH_PRIVATE_KEY detected: deploying opencode configuration..."

  # Ensure git is available (feature runs as root during build)
  if ! command -v git >/dev/null 2>&1; then
    apt_install git || true
  fi

  # Prepare an isolated SSH key owned by the dev user; never leave it behind.
  SSH_KEY_FILE="/tmp/.opencode-ssh/${NB_USER}_id_ed25519"
  cleanup_opencode_key() {
    rm -f "${SSH_KEY_FILE}" 2>/dev/null || true
    rmdir "$(dirname "${SSH_KEY_FILE}")" 2>/dev/null || true
  }
  trap cleanup_opencode_key EXIT

  umask 077
  mkdir -p "$(dirname "${SSH_KEY_FILE}")"
  printf '%s\n' "${SSH_PRIVATE_KEY}" > "${SSH_KEY_FILE}"
  chmod 600 "${SSH_KEY_FILE}"
  chown "${NB_UID}:${NB_GID}" "${SSH_KEY_FILE}"
  mkdir -p "${HOME_DIR}/.ssh"
  chmod 700 "${HOME_DIR}/.ssh"
  chown "${NB_UID}:${NB_GID}" "${HOME_DIR}/.ssh"

  # Run the clone + copy as the dev user so ownership is correct (no post chown).
  TMP_SCRIPT="/tmp/opencode-config-install-${NB_USER}.sh"
  cat > "${TMP_SCRIPT}" <<-'BASH'
#!/usr/bin/env bash
set -euo pipefail
SSH_KEY_FILE="$1"
OPENCODE_REPO="$2"
CONFIG_DIR="$3"

# SSH config scoped to github.com using the provided key (non-interactive).
mkdir -p "${HOME}/.ssh"
{
  printf 'Host github.com\n'
  printf '  HostName github.com\n'
  printf '  User git\n'
  printf '  IdentityFile %s\n' "${SSH_KEY_FILE}"
  printf '  IdentitiesOnly yes\n'
  printf '  UserKnownHostsFile /dev/null\n'
  printf '  StrictHostKeyChecking no\n'
} >> "${HOME}/.ssh/config"
chmod 600 "${HOME}/.ssh/config"

TMP_CLONE="$(mktemp -d)"
git clone --depth=1 "${OPENCODE_REPO}" "${TMP_CLONE}"
mkdir -p "${CONFIG_DIR}"
cp -a "${TMP_CLONE}/." "${CONFIG_DIR}/"
rm -rf "${TMP_CLONE}"
BASH
  chmod +x "${TMP_SCRIPT}"
  su - "${NB_USER}" -s /bin/bash -c "${TMP_SCRIPT} '${SSH_KEY_FILE}' '${OPENCODE_REPO}' '${CONFIG_DIR}'"
  rm -f "${TMP_SCRIPT}"

  chown -R "${NB_UID}:${NB_GID}" "${CONFIG_DIR}" || true
  echo "✅ opencode configuration deployed to ${CONFIG_DIR}"
else
  echo "ℹ️  SSH_PRIVATE_KEY not provided: skipping opencode configuration clone."
  echo "   The opencode binary is installed; provide SSH_PRIVATE_KEY at build time"
  echo "   to deploy the private ebpro/opencode-config repository."
fi

# ---------------------------------------------------------------------------
# 5. Verify installation
# ---------------------------------------------------------------------------
echo ""
echo "🔍 Verifying opencode installation..."
opencode --version

echo ""
echo "✅ opencode installed successfully!"
echo "   opencode version: $(opencode --version)"
