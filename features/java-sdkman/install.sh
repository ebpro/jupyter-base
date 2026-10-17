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

echo "java-sdk: installing SDKMAN"

if command -v sdk >/dev/null 2>&1; then
  echo "java-sdk: sdk already available"
  exit 0
fi

SDKMAN_DIR="${SDKMAN_DIR:-$HOME/.sdkman}"
export SDKMAN_DIR

echo "-> java-sdk: installing SDKMAN to $SDKMAN_DIR"

# Ensure per-user dirs exist and are owned correctly
if command -v fh_ensure_user_dirs >/dev/null 2>&1; then
  fh_ensure_user_dirs "${NB_USER:-jovyan}" "${NB_UID:-1001}" "${NB_GID:-1001}" "${HOME:-/home/${NB_USER:-jovyan}}" || true
fi

# If the SDKMAN directory exists but appears incomplete (missing init script),
# remove it so the installer can run cleanly. Creating an empty directory
# earlier in the build can cause the installer to detect a previous install
# and skip installation.
if [ -d "$SDKMAN_DIR" ] && [ ! -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]; then
  echo "java-sdk: found existing $SDKMAN_DIR without init script — removing to allow fresh install"
  chown -R "${NB_UID:-1001}:${NB_GID:-1001}" "$SDKMAN_DIR" 2>/dev/null || true
  rm -rf "$SDKMAN_DIR" || true
fi

# Run SDKMAN installer as the target non-root user so files land under their home
TMP_SCRIPT=$(mktemp)
cat > "$TMP_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SDKMAN_DIR="${SDKMAN_DIR:-$HOME/.sdkman}"
# Avoid 'set -u' causing errors inside the SDKMAN installer ($3 unbound variable)
set +u
# The SDKMAN bootstrap archive is downloaded INSIDE the upstream
# get.sdkman.io script, so a transient egress failure there (observed in CI:
# `curl: (35) Recv failure: Connection reset by peer`) surfaces only as this
# pipeline's status. The `|| true` that used to sit here discarded it, so the
# feature exited 0 having installed nothing. pipefail is turned on for THIS
# pipeline only, inside a subshell: neither the caller's nor the rest of this
# script's shell options change.
installer_rc=0
( set -o pipefail; curl -fsSL "https://get.sdkman.io?ci=true&rcupdate=false" | bash ) || installer_rc=$?
if [ "$installer_rc" -ne 0 ]; then
  echo "FH_SDKMAN_INSTALL_FAILED: the upstream SDKMAN installer (https://get.sdkman.io) exited ${installer_rc} for the target user (HOME=${HOME}); SDKMAN was NOT installed. This stage performs a build-time network fetch." >&2
  exit 1
fi
set -u
# Hard post-condition: no init artefact means no SDKMAN, whatever the
# installer's exit status claimed. Checked here, in the target user's shell,
# because this is the shell whose $HOME the installer actually wrote to.
if [ ! -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]; then
  echo "FH_SDKMAN_INSTALL_FAILED: the SDKMAN installer exited 0 but left no init artefact at $SDKMAN_DIR/bin/sdkman-init.sh (HOME=${HOME}); treating SDKMAN as not installed." >&2
  exit 1
fi

# Avoid 'set -u' causing errors inside the SDKMAN init script
set +u
# shellcheck source=/dev/null
source "$SDKMAN_DIR/bin/sdkman-init.sh"
set -u
EOF

chown "${NB_UID:-1001}:${NB_GID:-1001}" "$TMP_SCRIPT" 2>/dev/null || true
# The installer run's exit status is the first authoritative signal and must
# not be masked: a failing fetch, a missing init artefact or an unusable
# target account all mean this feature delivered nothing.
installer_rc=0
su - ${NB_USER:-jovyan} -s /bin/bash -c "bash '$TMP_SCRIPT'" || installer_rc=$?
rm -f "$TMP_SCRIPT"
if [ "$installer_rc" -ne 0 ]; then
  echo "❌ java-sdk: FH_SDKMAN_INSTALL_FAILED — the SDKMAN installer run for ${NB_USER:-jovyan} exited ${installer_rc}, so SDKMAN is not installed. Aborting at the producer instead of letting java-jdk / java-maven / java-gradle report 'SDKMAN not available' minutes later and absorb the blame (see the FH_SDKMAN_INSTALL_FAILED line above for the cause)." >&2
  exit 1
fi

# Try to source the initialization script for the active shell
if [ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]; then
  set +u
  # shellcheck source=/dev/null
  source "$SDKMAN_DIR/bin/sdkman-init.sh"
  set -u
fi

# Second post-condition, evaluated exactly the way every consumer evaluates
# it: as a login shell of the target user that sources the init script and
# then looks for `sdk`. Distinct exit statuses so the log says which
# guarantee broke instead of shrugging.
sdk_probe_rc=0
su - ${NB_USER:-jovyan} -s /bin/bash -lc 'set +u; [ -s "$HOME/.sdkman/bin/sdkman-init.sh" ] || exit 3; source "$HOME/.sdkman/bin/sdkman-init.sh" >/dev/null 2>&1 || exit 4; command -v sdk >/dev/null 2>&1 || exit 5' || sdk_probe_rc=$?
if [ "$sdk_probe_rc" -ne 0 ]; then
  case "$sdk_probe_rc" in
    3) cause="no init artefact at \$HOME/.sdkman/bin/sdkman-init.sh for ${NB_USER:-jovyan}" ;;
    4) cause="sdkman-init.sh could not be sourced by ${NB_USER:-jovyan}" ;;
    5) cause="'sdk' is not resolvable for ${NB_USER:-jovyan} even after sourcing sdkman-init.sh" ;;
    *) cause="the SDKMAN probe for ${NB_USER:-jovyan} could not be executed (exit ${sdk_probe_rc})" ;;
  esac
  echo "❌ java-sdk: FH_SDKMAN_INSTALL_FAILED — ${cause}. SDKMAN is not usable by the consumers this feature exists to serve (java-jdk, java-maven, java-gradle, kotlin)." >&2
  exit 1
fi
echo "java-sdk: SDKMAN installed for ${NB_USER:-jovyan}"

# If running as root, ensure ownership of the SDKMAN directory matches the HOME owner
if [ "$(id -u)" -eq 0 ]; then
  if stat -c '%u:%g' "$HOME" >/dev/null 2>&1; then
    owner_gid=$(stat -c '%u:%g' "$HOME") || true
    [ -n "$owner_gid" ] && chown -R "$owner_gid" "$SDKMAN_DIR" 2>/dev/null || true
  else
    if [ -n "${NB_USER:-}" ]; then
      chown -R "${NB_USER}:${NB_GID:-}" "$SDKMAN_DIR" 2>/dev/null || true
    fi
  fi
fi

echo "java-sdk: SDKMAN installation complete"
echo "java-sdk: Use java-jdk, java-maven, or java-gradle features to install tools"
exit 0
