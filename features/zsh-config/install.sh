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

# Resolve the version from the SoT (versions/versions.yaml -> versions.json),
# fail closed. starship is checksum-pinned (checksums.json tools.starship) and
# mirrored by scripts/stage-toolcache.sh; it must never fall back to upstream
# "latest" or to a bare curl (hadolint/ctop/dive precedent).
resolve_version(){
  local tool="$1" v=""
  if command -v fh_resolve_version >/dev/null 2>&1; then
    v=$(fh_resolve_version "$tool" || true)
    if [ -n "$v" ]; then
      echo "$v"; return 0
    fi
  fi
  if [ -f "${PWD}/artefacts/versions.json" ]; then
    v=$(jq -r --arg t "$tool" '.tools[$t] // empty' "${PWD}/artefacts/versions.json" 2>/dev/null || true)
  elif [ -f /tmp/versions.json ]; then
    v=$(jq -r --arg t "$tool" '.tools[$t] // empty' /tmp/versions.json 2>/dev/null || true)
  fi
  echo "$v"
}

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

  # Install starship as the user if missing — pinned, digest-verified and
  # mirrored (hadolint/ctop/dive pattern). The piped upstream installer this
  # block used to run resolved the asset as "latest" and died on transient
  # GitHub/starship.rs egress (run 39129344307: curl (35) mid-fetch, twice);
  # download_direct serves the same tarball from /opt/toolcache when staged
  # and verifies it against checksums.json either way. The fatality introduced
  # by 9225c0d is preserved: every failure path below exits 1 with
  # FH_STARSHIP_INSTALL_FAILED (or FH_VERSION_UNRESOLVED) — no `|| true` mask.
  if ! su - ${NB_USER} -c "command -v starship >/dev/null 2>&1"; then
    if ! command -v curl >/dev/null 2>&1; then
      # download_direct fetches with curl on a toolcache miss; keep the
      # precondition the piped installer used to guarantee.
      apt_install curl || true
    fi

    VERSION=$(resolve_version "starship")
    if [ -z "$VERSION" ]; then
      echo "❌ zsh-config: FH_VERSION_UNRESOLVED — pinned version for 'starship' not found via fh_resolve_version/artefacts; refusing to fall back to upstream 'latest' (checksum-pinned tool)" >&2
      exit 1
    fi

    if ! command -v download_direct >/dev/null 2>&1; then
      echo "❌ zsh-config: FH_STARSHIP_INSTALL_FAILED — download_direct helper not found (features/_lib/download-release must run first); refusing to fall back to an unpinned installer fetch." >&2
      exit 1
    fi

    ARCH=$(dpkg --print-architecture)

    # Map architecture names for the GitHub release assets. musl on both
    # arches — the same assets upstream's own installer resolved at "latest"
    # (amd64 -> x86_64-unknown-linux-musl, arm64 -> aarch64-unknown-linux-musl).
    case "${ARCH}" in
      amd64) RELEASE_ARCH="x86_64" ;;
      arm64) RELEASE_ARCH="aarch64" ;;
      *) echo "Unsupported architecture: ${ARCH}"; exit 1 ;;
    esac

    # The upstream asset basename is UNVERSIONED; the pin lives in the release
    # tag (v${VERSION}) and the digest in checksums.json tools.starship. The
    # tarball holds only the executable 'starship' binary at its root ->
    # extract=true (never rename a tarball as raw). Install dir is the
    # user-local bin this feature's own contract asserts:
    # feature.json postInstallCheck `test -x /home/jovyan/.local/bin/starship`.
    DOWNLOAD_URL="https://github.com/starship/starship/releases/download/v${VERSION}/starship-${RELEASE_ARCH}-unknown-linux-musl.tar.gz"
    mkdir -p "${HOME_DIR}/.local/bin"
    starship_rc=0
    download_direct "$DOWNLOAD_URL" "starship" "$VERSION" "${HOME_DIR}/.local/bin" true || starship_rc=$?
    if [ "$starship_rc" -ne 0 ]; then
      echo "FH_STARSHIP_INSTALL_FAILED: download_direct of the pinned archive (${DOWNLOAD_URL}) exited ${starship_rc}; starship was NOT installed at ${HOME_DIR}/.local/bin/starship. The archive is digest-verified against checksums.json and served from the toolcache mirror when staged." >&2
      exit 1
    fi

    # download_direct runs as root (this whole feature does); hand the tree
    # back to the user before the su'd zshrc wiring below.
    chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/.local" || true

    TMP_SCRIPT_STARSHIP="/tmp/starship-zshrc-${NB_USER}.sh"
    cat > "${TMP_SCRIPT_STARSHIP}" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
grep -q '^eval "\$(starship init zsh)"' ~/.zshrc 2>/dev/null || printf '%s\n' 'eval "$(starship init zsh)"' >> ~/.zshrc
BASH
    chmod +x "${TMP_SCRIPT_STARSHIP}" || true
    # The zshrc wiring runs as the user and its exit status is authoritative,
    # exactly as before 9225c0d removed the double `|| true` that had kept a
    # feature installing no starship while reporting success.
    starship_su_rc=0
    su - ${NB_USER} -s /bin/bash -c "${TMP_SCRIPT_STARSHIP}" || starship_su_rc=$?
    rm -f "${TMP_SCRIPT_STARSHIP}" || true
    if [ "$starship_su_rc" -ne 0 ]; then
      echo "❌ zsh-config: FH_STARSHIP_INSTALL_FAILED — the starship zshrc wiring for ${NB_USER} exited ${starship_su_rc}, so the prompt is not initialised in ${HOME_DIR}/.zshrc even though the binary is at ${HOME_DIR}/.local/bin/starship. Aborting at the producer rather than publishing an image that advertises a starship prompt and renders none." >&2
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
    echo "❌ zsh-config: FH_STARSHIP_INSTALL_FAILED — no executable starship at ${HOME_DIR}/.local/bin/starship for ${NB_USER} after the install stage (origin: the pinned release asset in checksums.json tools.starship). postInstallCheck asserts this exact path; aborting rather than publishing an image that advertises a prompt it cannot render." >&2
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

