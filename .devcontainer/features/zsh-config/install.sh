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

PREZTO_REPO="${DEVCONTAINER_ZSH_CONFIG_PREZTO_REPO:-https://github.com/sorin-ionescu/prezto.git}"
NB_USER=${NB_USER:-jovyan}
NB_UID=${NB_UID:-1001}
NB_GID=${NB_GID:-1001}
HOME_DIR="/home/${NB_USER}"

echo "zsh-config: installing prezto for ${NB_USER}"

if [ ! -d "${HOME_DIR}/.zprezto" ]; then
  su - ${NB_USER} -c "git clone --depth=1 --recursive '${PREZTO_REPO}' '${HOME_DIR}/.zprezto'" || true
fi

# If an init script exists in the repo path, try to run it as the user (idempotent)
if [ -f /tmp/initzsh.sh ]; then
  su - ${NB_USER} -c "zsh -c /tmp/initzsh.sh" || true
fi

# Ensure p10k is referenced in .zshrc
if ! su - ${NB_USER} -c "grep -q '\.p10k.zsh' ~/.zshrc" >/dev/null 2>&1; then
  su - ${NB_USER} -c "echo '[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh' >> ~/.zshrc"
fi

chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/.zprezto" || true
echo "zsh-config: done"
