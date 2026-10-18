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
# Respects a caller-provided HOME_DIR -- the ${HOME_DIR:-/home/${NB_USER}} form
# this repo already standardises on (tests/test_kotlin_kernel_contract.py:171-172
# pins that exact shape for kotlin-kernel) -- and otherwise derives it as before.
HOME_DIR="${HOME_DIR:-/home/${NB_USER}}"

echo "zsh-config: configuring zsh for ${NB_USER}"

# Ensure git is available (feature runs as root during build)
if ! command -v git >/dev/null 2>&1; then
  apt_install git || true
fi
# Run the zshrc updates as `NB_USER` so that files are created with correct
# ownership and no post-build chown is required.
if [ -d "${HOME_DIR}" ]; then
  # Write a temporary user-run script to avoid outer-shell expansion issues
  TMP_SCRIPT="/tmp/zsh-config-install-${NB_USER}.sh"
  cat > "${TMP_SCRIPT}" <<-'BASH'
#!/usr/bin/env bash
set -euo pipefail
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
  # Run it as the target user
  su - ${NB_USER} -s /bin/bash -c "${TMP_SCRIPT}" || true

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
# The upstream installer is fetched and piped to sh in ONE pipeline, so a
# transient egress failure surfaces only through the pipeline's status: `sh`
# happily exits 0 on empty input. pipefail is turned on for THIS pipeline only,
# inside a subshell, so nothing else in this script changes shell options. The
# `|| true` that used to sit here discarded even a genuine failure, which is how
# this feature exited 0 having installed no starship while its own
# postInstallCheck asserts $HOME/.local/bin/starship.
starship_rc=0
( set -o pipefail; curl -fsSL https://starship.rs/install.sh | sh -s -- -y --bin-dir "$HOME/.local/bin" ) || starship_rc=$?
if [ "$starship_rc" -ne 0 ]; then
  echo "FH_STARSHIP_INSTALL_FAILED: the upstream starship installer (https://starship.rs/install.sh) exited ${starship_rc} for the target user (HOME=${HOME}); starship was NOT installed at $HOME/.local/bin/starship. This stage performs a build-time network fetch." >&2
  exit 1
fi
grep -q '^eval "\$(starship init zsh)"' ~/.zshrc 2>/dev/null || printf '%s\n' 'eval "$(starship init zsh)"' >> ~/.zshrc
BASH
    chmod +x "${TMP_SCRIPT_STARSHIP}" || true
    # The installer run's exit status is the second authoritative signal and must
    # not be masked either. Together with the `|| true` on the fetch it formed a
    # DOUBLE mask: neither a failed download nor an unusable target account could
    # fail the build, so the leg stayed green while postInstallCheck failed.
    starship_su_rc=0
    su - ${NB_USER} -s /bin/bash -c "${TMP_SCRIPT_STARSHIP}" || starship_su_rc=$?
    rm -f "${TMP_SCRIPT_STARSHIP}" || true
    if [ "$starship_su_rc" -ne 0 ]; then
      echo "❌ zsh-config: FH_STARSHIP_INSTALL_FAILED — the starship installer run for ${NB_USER} exited ${starship_su_rc}, so starship is not installed at ${HOME_DIR}/.local/bin/starship (origin: https://starship.rs/install.sh). Aborting at the producer rather than publishing an image that advertises a starship prompt and ships none (the FH_STARSHIP_INSTALL_FAILED line above carries the cause)." >&2
      exit 1
    fi
  fi

  # Ensure ownership (in case any files were created by root earlier)
  chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}" || true
  rm -f "${TMP_SCRIPT}" || true

  # Hard post-condition: the guarantee this feature exists to deliver is an
  # executable starship at the exact path its own contract check asserts
  # (feature.json: `test -x /home/jovyan/.local/bin/starship`). HOME_DIR and not
  # HOME, because the producer runs as root and $HOME there is /root. A zero exit
  # from the install stage proves nothing on its own -- that is the shape the
  # removed `|| true` pair hid, on 6 tags whose postInstallCheck failed.
  if [ ! -x "${HOME_DIR}/.local/bin/starship" ]; then
    echo "❌ zsh-config: FH_STARSHIP_INSTALL_FAILED — no executable starship at ${HOME_DIR}/.local/bin/starship for ${NB_USER} after the install stage (origin: https://starship.rs/install.sh). postInstallCheck asserts this exact path; aborting rather than publishing an image that advertises a prompt it cannot render." >&2
    exit 1
  fi
else
  # container-user is a declared dependency (feature.json) and owns the creation
  # of this directory. Without it neither the ~/.zshrc configuration nor the
  # starship binary can exist, so the whole block silently delivering nothing and
  # reporting success is the same masking class as the `|| true` pair above.
  echo "❌ zsh-config: FH_ZSH_HOME_MISSING — no home directory at ${HOME_DIR} for user ${NB_USER}. container-user (declared dependency) must create it before this feature runs; without it neither ${HOME_DIR}/.zshrc configuration nor ${HOME_DIR}/.local/bin/starship can exist." >&2
  exit 1
fi

echo "zsh-config: done (installed as ${NB_USER})"

