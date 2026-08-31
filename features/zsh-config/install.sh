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

PREZTO_REPO="${DEVCONTAINER_ZSH_CONFIG_PREZTO_REPO:-https://github.com/sorin-ionescu/prezto.git}"
NB_USER=${NB_USER:-jovyan}
NB_UID=${NB_UID:-1001}
NB_GID=${NB_GID:-1001}
HOME_DIR="/home/${NB_USER}"

echo "zsh-config: installing prezto for ${NB_USER}"

# Ensure git is available (feature runs as root during build)
if ! command -v git >/dev/null 2>&1; then
  apt_install git || true
fi
# Perform the canonical prezto install as the non-root user during build.
# Run the clone, runcom symlink creation, and zshrc updates as `NB_USER` so
# that files are created with correct ownership and no post-build chown is
# required. This follows the standard prezto instructions.
if [ -d "${HOME_DIR}" ]; then
  # Write a temporary user-run script to avoid outer-shell expansion issues
  TMP_SCRIPT="/tmp/zsh-config-install-${NB_USER}.sh"
  cat > "${TMP_SCRIPT}" <<-'BASH'
#!/usr/bin/env bash
set -euo pipefail
if [ ! -d "$HOME/.zprezto" ]; then
  git clone --depth=1 --recursive "${PREZTO_REPO}" "$HOME/.zprezto" || true
fi
if [ -d "$HOME/.zprezto/runcoms" ]; then
  for rc in "$HOME/.zprezto/runcoms"/*; do
    base=$(basename "$rc")
    [ "$base" = "README.md" ] && continue
    ln -sf "$rc" "$HOME/.${base}" || true
  done
fi
# Ensure ~/.zshrc sources prezto init
if ! grep -q '^source ~/.zprezto/init.zsh' ~/.zshrc 2>/dev/null; then
  printf '%s\n' 'source ~/.zprezto/init.zsh' >> ~/.zshrc
fi
# Ensure ~/.local/bin exists and is on PATH in ~/.zshrc
mkdir -p ~/.local/bin
if ! grep -q "export PATH=\"$HOME/.local/bin:\$PATH\"" ~/.zshrc 2>/dev/null; then
  printf '%s\n' "export PATH=\"$HOME/.local/bin:\$PATH\"" >> ~/.zshrc
fi
# Source /etc/profile.d/*.sh for system-wide environment (e.g., QUARTO_PYTHON)
if ! grep -q '/etc/profile.d/\*.sh' ~/.zshrc 2>/dev/null; then
  printf '%s\n' '# Source system-wide environment from /etc/profile.d' >> ~/.zshrc
  printf '%s\n' 'for script in /etc/profile.d/*.sh; do' >> ~/.zshrc
  printf '%s\n' '  [ -r "$script" ] && source "$script"' >> ~/.zshrc
  printf '%s\n' 'done' >> ~/.zshrc
fi
BASH
  chmod +x "${TMP_SCRIPT}" || true
  # Run it as the target user, supplying PREZTO_REPO in the environment
  su - ${NB_USER} -s /bin/bash -c "PREZTO_REPO='${PREZTO_REPO}' ${TMP_SCRIPT}" || true

  # Ensure user's cache dir exists and is owned by the user (prevents starship write errors)
  mkdir -p "${HOME_DIR}/.cache" || true
  chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/.cache" || true

  # Install starship as the user if missing
  if ! su - ${NB_USER} -c "command -v starship >/dev/null 2>&1"; then
    if ! command -v curl >/dev/null 2>&1; then
      apt_install curl || true
    fi
    TMP_SCRIPT_STARSHIP="/tmp/starship-install-${NB_USER}.sh"
    cat > "${TMP_SCRIPT_STARSHIP}" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$HOME/.local/bin" >/dev/null 2>&1 || true
curl -fsSL https://starship.rs/install.sh | sh -s -- -y --bin-dir ~/.local/bin || true
grep -q '^eval "\$(starship init zsh)"' ~/.zshrc 2>/dev/null || printf '%s\n' 'eval "$(starship init zsh)"' >> ~/.zshrc
BASH
    chmod +x "${TMP_SCRIPT_STARSHIP}" || true
    su - ${NB_USER} -s /bin/bash -c "${TMP_SCRIPT_STARSHIP}" || true
    rm -f "${TMP_SCRIPT_STARSHIP}" || true
  fi

  # Ensure ownership (in case any files were created by root earlier)
  chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}" || true
  rm -f "${TMP_SCRIPT}" || true
fi

echo "zsh-config: done (installed as ${NB_USER})"

