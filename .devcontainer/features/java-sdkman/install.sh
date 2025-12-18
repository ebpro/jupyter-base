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

echo "java-sdk: installing SDKMAN"

if command -v sdk >/dev/null 2>&1; then
  echo "java-sdk: sdk already available"
  exit 0
fi

SDKMAN_DIR="${SDKMAN_DIR:-$HOME/.sdkman}"
export SDKMAN_DIR
INSTALL_MAVEN="${INSTALL_MAVEN:-false}"
export INSTALL_MAVEN
INSTALL_GRADLE="${INSTALL_GRADLE:-false}"
export INSTALL_GRADLE

echo "-> java-sdk: installing SDKMAN to $SDKMAN_DIR"
echo "-> java-sdk: install maven=$INSTALL_MAVEN gradle=$INSTALL_GRADLE"

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
curl -s "https://get.sdkman.io" | bash || true
if [ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]; then
  # Avoid 'set -u' causing errors inside the SDKMAN init script
  set +u
  # shellcheck source=/dev/null
  source "$SDKMAN_DIR/bin/sdkman-init.sh"
  set -u
fi
EOF

chown "${NB_UID:-1001}:${NB_GID:-1001}" "$TMP_SCRIPT" 2>/dev/null || true
su - ${NB_USER:-jovyan} -s /bin/bash -c "bash '$TMP_SCRIPT'" || true
rm -f "$TMP_SCRIPT"

# Try to source the initialization script for the active shell
if [ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]; then
  set +u
  # shellcheck source=/dev/null
  source "$SDKMAN_DIR/bin/sdkman-init.sh"
  set -u
fi

if su - ${NB_USER:-jovyan} -s /bin/bash -lc 'set +u; [ -s "$HOME/.sdkman/bin/sdkman-init.sh" ] && source "$HOME/.sdkman/bin/sdkman-init.sh" >/dev/null 2>&1; command -v sdk >/dev/null 2>&1'; then
  echo "java-sdk: SDKMAN installed for ${NB_USER:-jovyan}"
else
  echo "java-sdk: SDKMAN installation completed but 'sdk' not exposed in PATH for ${NB_USER:-jovyan}" >&2
fi

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

# Helper: interpret boolean-ish env vars (true/1/yes/on)
is_true() {
  case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}



if su - ${NB_USER:-jovyan} -s /bin/bash -lc 'set +u; [ -s "$HOME/.sdkman/bin/sdkman-init.sh" ] && source "$HOME/.sdkman/bin/sdkman-init.sh" >/dev/null 2>&1 || true; command -v sdk >/dev/null 2>&1'; then
  # Build a small script to run candidate installs as the NB_USER
  CAND_SCRIPT=$(mktemp)
  cat > "$CAND_SCRIPT" <<'EOF'
#!/usr/bin/env bash
# keep -u disabled while interacting with SDKMAN to avoid failures
set -eo pipefail
SDKMAN_DIR="${SDKMAN_DIR:-$HOME/.sdkman}"
if [ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]; then
  # source under 'set +u' semantics (do not re-enable -u)
  set +u
  # shellcheck source=/dev/null
  source "$SDKMAN_DIR/bin/sdkman-init.sh"
  # leave -u disabled to allow SDKMAN internals to reference unset vars
fi
EOF

  if is_true "$INSTALL_MAVEN"; then
    echo "echo 'java-sdk: installing maven via sdk'" >> "$CAND_SCRIPT"
    echo "sdk install maven || true" >> "$CAND_SCRIPT"
  else
    echo "echo 'java-sdk: skipping maven install'" >> "$CAND_SCRIPT"
  fi
  if is_true "$INSTALL_GRADLE"; then
    echo "echo 'java-sdk: installing gradle via sdk'" >> "$CAND_SCRIPT"
    echo "sdk install gradle || true" >> "$CAND_SCRIPT"
  else
    echo "echo 'java-sdk: skipping gradle install'" >> "$CAND_SCRIPT"
  fi


  # Run candidate installs if any were added to the script
  if grep -q 'sdk install' "$CAND_SCRIPT"; then
    chown "${NB_UID:-1001}:${NB_GID:-1001}" "$CAND_SCRIPT" 2>/dev/null || true
    # Run candidate installs in a login shell that sources SDKMAN init so 'sdk' is available
    su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; bash '$CAND_SCRIPT'" || true
    rm -f "$CAND_SCRIPT"
  else
    rm -f "$CAND_SCRIPT"
  fi
fi

exit 0
