#!/usr/bin/env bash
set -euo pipefail

# java-devtools v2.0 - Meta-feature install script
# This feature now delegates to granular features: java-jdk, java-maven, java-gradle
# The actual installation is handled by those features through dependsOn.

echo "java-devtools: Meta-feature - delegates to java-jdk, java-maven, java-gradle"
echo "java-devtools: This feature is maintained for backward compatibility"
echo "java-devtools: Consider using granular features directly for better caching"

# Verify installation
verify_java() {
  local ver="$1"
  local dist_id="${SDKMAN_JAVA_IDENTIFIER:-temurin}"
  echo "java-devtools: ensuring JDK (sdkman candidate=${dist_id}) version=${ver}"
  if ! command -v sdk >/dev/null 2>&1; then
    if ! ensure_sdkman; then
      echo "java-devtools: sdk (SDKMAN) not available. Please include java-sdk feature or enable INSTALL_SDKMAN" >&2
      return 1
    fi
  fi

  # helper: query SDKMAN list for a matching candidate (run as NB_USER)
  query_candidate() {
    local pattern="$1"
    su - ${NB_USER:-jovyan} -s /bin/bash -lc \
      "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; sdk list java | grep -E \"${pattern}\" | awk '{print \$NF}' | head -n1" || true
  }

  local cand

  # default behaviour: let sdk pick the distribution/version
  if [ -z "${ver:-}" ] || [ "${ver}" = "default" ]; then
    echo "java-devtools: installing default java via sdk"
    su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; sdk install java" || true
    return 0
  fi

  # 'ea' -> latest openjdk EA
  if [ "${ver}" = "ea" ]; then
    echo "java-devtools: selecting latest openjdk EA via SDKMAN"
    cand=$(query_candidate "openjdk.*ea|openjdk.*-ea") || true
    if [ -n "${cand}" ]; then
      su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; sdk install java ${cand}" || true
    else
      echo "java-devtools: no openjdk EA candidate found; falling back to default sdk install"
      su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; sdk install java" || true
    fi
    return 0
  fi

  # 'latest' -> first temurin candidate ending with -tem
  if [ "${ver}" = "latest" ]; then
    echo "java-devtools: selecting latest ${dist_id} -tem candidate via SDKMAN"
    cand=$(su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; sdk list java | tr -d ' ' | cut -f 6 -d '|' | grep '.*-tem\$' | head -n1") || true
    if [ -n "${cand}" ]; then
      su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; sdk install java ${cand}" || true
    else
      echo "java-devtools: no ${dist_id} -tem candidate found; falling back to default"
      su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; sdk install java" || true
    fi
    return 0
  fi

  # numeric major version -> first temurin candidate starting with X.
  if echo "${ver}" | grep -Eq '^[0-9]+$'; then
    echo "java-devtools: selecting ${dist_id} candidates starting with ${ver} and ending with -tem"
    cand=$(su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; sdk list java | tr -d ' ' | cut -f 6 -d '|' | grep '^${ver}\\..*-tem' | head -n1") || true
    if [ -n "${cand}" ]; then
      su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; sdk install java ${cand}" || true
    else
      echo "java-devtools: no matching ${dist_id} candidate for major ${ver}; trying generic fallback"
      su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; sdk install java" || true
    fi
    return 0
  fi

  # fallback: try installing by explicit version string
  echo "java-devtools: attempting sdk install java ${dist_id}-${ver}"
  su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; sdk install java ${dist_id}-${ver}" || \
    su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; sdk install java" || true
}

# Ensure SDKMAN is installed for the NB_USER (idempotent). Returns 0 if sdk available.
ensure_sdkman() {
  # Check if sdk available in the NB_USER login shell
  if su - ${NB_USER:-jovyan} -s /bin/bash -lc 'set +u; [ -s "$HOME/.sdkman/bin/sdkman-init.sh" ] && source "$HOME/.sdkman/bin/sdkman-init.sh" >/dev/null 2>&1 || true; command -v sdk >/dev/null 2>&1'; then
    return 0
  fi

  # If INSTALL_SDKMAN explicitly disabled, do not attempt install
  if [ "${INSTALL_SDKMAN}" = "false" ]; then
    return 1
  fi

  TMP_SCRIPT=$(mktemp)
  cat > "$TMP_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SDKMAN_DIR="${SDKMAN_DIR:-$HOME/.sdkman}"
curl -s "https://get.sdkman.io" | bash || true
if [ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]; then
  set +u
  # shellcheck source=/dev/null
  source "$SDKMAN_DIR/bin/sdkman-init.sh"
fi
EOF

  chown "${NB_UID:-1001}:${NB_GID:-1001}" "$TMP_SCRIPT" 2>/dev/null || true
  su - ${NB_USER:-jovyan} -s /bin/bash -c "bash '$TMP_SCRIPT'" || true
  rm -f "$TMP_SCRIPT"

  # Ensure ownership of SDKMAN dir
  if [ -d "${HOME:-/home/${NB_USER:-jovyan}}/.sdkman" ]; then
    chown -R "${NB_UID:-1001}:${NB_GID:-1001}" "${HOME:-/home/${NB_USER:-jovyan}}/.sdkman" 2>/dev/null || true
  fi

  # Final check
  if su - ${NB_USER:-jovyan} -s /bin/bash -lc 'set +u; [ -s "$HOME/.sdkman/bin/sdkman-init.sh" ] && source "$HOME/.sdkman/bin/sdkman-init.sh" >/dev/null 2>&1 || true; command -v sdk >/dev/null 2>&1'; then
    return 0
  fi
  return 1
}

# Ensure requested JDK is installed early so subsequent tool installs can use it
install_jdk "$JDK_VERSION" || true

if [ "$INSTALL_MAVEN" = "true" ]; then
  if command -v mvn >/dev/null 2>&1; then
    echo "maven already installed"
  else
    if ! command -v sdk >/dev/null 2>&1; then
      if ! ensure_sdkman; then
        echo "java-devtools: SDKMAN not available; please include java-sdk or set INSTALL_SDKMAN=true to allow auto-install" >&2
      fi
    fi
    if command -v sdk >/dev/null 2>&1; then
      echo "java-devtools: installing Maven via SDKMAN"
      su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; sdk install maven" || true
    fi
  fi
fi

if [ "$INSTALL_GRADLE" = "true" ]; then
  if command -v gradle >/dev/null 2>&1; then
    echo "gradle already installed"
  else
    if ! command -v sdk >/dev/null 2>&1; then
      if ! ensure_sdkman; then
        echo "java-devtools: SDKMAN not available; please include java-sdk or set INSTALL_SDKMAN=true to allow auto-install" >&2
      fi
    fi
    if command -v sdk >/dev/null 2>&1; then
      echo "java-devtools: installing Gradle via SDKMAN"
      su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; sdk install gradle" || true
    fi
  fi
fi

if [ "$INSTALL_JDTLS" = "true" ]; then
  echo "java-devtools: installing jdtls (language server)"
  # placeholder: installation steps depend on distribution; prefer downloading release
  echo "Please configure JDTLS download URL via ARTIFACTS_BASE_URL or system package manager"
fi

echo "java-devtools: done"
