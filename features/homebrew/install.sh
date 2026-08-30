#!/usr/bin/env bash
set -euo pipefail

# Install Homebrew (Linux) into /home/$NB_USER/.linuxbrew by default
NB_USER=${NB_USER:-jovyan}
BREW_PREFIX="/home/${NB_USER}/.linuxbrew"

if command -v brew >/dev/null 2>&1; then
  echo "brew already installed: $(brew --version)"
  exit 0
fi

mkdir -p "${BREW_PREFIX}"
chown -R "${NB_USER}:" "${BREW_PREFIX}" || true

TMP_INSTALLER="/tmp/homebrew-install.sh"
curl -fsSL -o "${TMP_INSTALLER}" https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh
chown "${NB_USER}:" "${TMP_INSTALLER}" || true

if command -v sudo >/dev/null 2>&1; then
  sudo -u "${NB_USER}" bash "${TMP_INSTALLER}"
else
  su - "${NB_USER}" -c "bash ${TMP_INSTALLER}"
fi

# Ensure profile.d entry so brew is on PATH for all users
cat > /etc/profile.d/homebrew.sh <<'EOF'
export PATH="${HOME}/.linuxbrew/bin:${HOME}/.linuxbrew/opt/bin:$PATH"
export HOMEBREW_PREFIX="${HOME}/.linuxbrew"
EOF
chmod 644 /etc/profile.d/homebrew.sh || true

echo "Homebrew install finished (prefix=${BREW_PREFIX})"
