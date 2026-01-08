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

echo "java-sdk: SDKMAN installation complete"
echo "java-sdk: Use java-jdk, java-maven, or java-gradle features to install tools"

exit 0
