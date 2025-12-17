#!/usr/bin/env bash
set -euo pipefail

# java-devtools install
## Profile-variable normalization
# Supported environment/profile variables:
# - INSTALL_SDKMAN: true/false (install SDKMAN)
# - JDK_VERSION: numeric major, 'latest' or 'ea'
# - INSTALL_JAVA_LTS / INSTALL_JAVA_LATEST: support for bulk installs (not used when JDK_VERSION set)
# - INSTALL_MAVEN / INSTALL_GRADLE / INSTALL_JDTLS: install tools via SDKMAN
INSTALL_SDKMAN=${INSTALL_SDKMAN:-true}
JDK_VERSION=${JDK_VERSION:-25}
INSTALL_JAVA_LTS=${INSTALL_JAVA_LTS:-false}
INSTALL_JAVA_LATEST=${INSTALL_JAVA_LATEST:-false}
INSTALL_MAVEN=${INSTALL_MAVEN:-true}
INSTALL_GRADLE=${INSTALL_GRADLE:-false}
INSTALL_JDTLS=${INSTALL_JDTLS:-false}

echo "java-devtools: INSTALL_SDKMAN=$INSTALL_SDKMAN JDK_VERSION=$JDK_VERSION INSTALL_JAVA_LTS=$INSTALL_JAVA_LTS INSTALL_JAVA_LATEST=$INSTALL_JAVA_LATEST"
echo "java-devtools: maven=$INSTALL_MAVEN gradle=$INSTALL_GRADLE jdtls=$INSTALL_JDTLS"

echo "----> JDK_VERSION is set to '$JDK_VERSION'"

# Install SDKMAN if it's not already present. This is idempotent.
install_sdkman() {
  if command -v sdk >/dev/null 2>&1; then
    echo "java-devtools: sdk already available"
    return 0
  fi
  SDKMAN_DIR=${SDKMAN_DIR:-"$HOME/.sdkman"}
  INIT_SH="$SDKMAN_DIR/bin/sdkman-init.sh"
  if [[ -f "$INIT_SH" ]]; then
    echo "java-devtools: SDKMAN init already present at $INIT_SH"
    # Ensure SDKMAN_DIR is exported for the init script and source safely
    export SDKMAN_DIR
    # shellcheck disable=SC1090
    set +u; source "$INIT_SH" || true; set -u
    return 0
  fi

  echo "java-devtools: installing SDKMAN (non-interactive)"
  if command -v curl >/dev/null 2>&1; then
    curl -s "https://get.sdkman.io" | bash || true
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "https://get.sdkman.io" | bash || true
  else
    echo "java-devtools: neither curl nor wget available to install SDKMAN" >&2
    return 1
  fi

  if [[ -f "$INIT_SH" ]]; then
    # Ensure SDKMAN_DIR is exported for the init script and source safely
    export SDKMAN_DIR
    # shellcheck disable=SC1090
    set +u; source "$INIT_SH" || true; set -u
    # Provide defaults for variables the SDKMAN scripts expect when 'set -u' is active
    export SDKMAN_OFFLINE_MODE=${SDKMAN_OFFLINE_MODE:-false}
    export SDKMAN_CANDIDATES_API=${SDKMAN_CANDIDATES_API:-"https://api.sdkman.io/2"}
    export SDKMAN_PLATFORM=${SDKMAN_PLATFORM:-"UNIX"}
    echo "java-devtools: SDKMAN installed and initialized"
  else
    echo "java-devtools: SDKMAN installation did not produce $INIT_SH" >&2
    return 1
  fi
}

# Ensure SDKMAN is installed so subsequent steps can use `sdk`
install_sdkman || true

## Install exactly one JDK version via SDKMAN according to JDK_VERSION (default: 17)
JDK_VERSION=${JDK_VERSION:-21}
echo "java-devtools: requested JDK_VERSION=${JDK_VERSION}"
if command -v sdk >/dev/null 2>&1; then
  echo "java-devtools: querying SDKMAN for Temurin candidates (for major ${JDK_VERSION})"
  # Capture sdk list output for diagnostics (useful when running inside Docker builds)
  set +u
  sdk_list=$(sdk list java 2>/dev/null || true)
  set -u
  echo "java-devtools: sdk list size: $(printf '%s' "$sdk_list" | wc -c)"
  # Extract Temurin candidates (field 6 from table output, trimmed)
  candidates=$(printf '%s\n' "$sdk_list" | tr -s ' ' | grep ' tem ' | cut -d '|' -f 6 | tr -d ' ' || true)

  chosen_candidate=""
  if [[ -n "$candidates" || -n "$sdk_list" ]]; then
    if [[ "${JDK_VERSION}" == "latest" ]]; then
      # Pick the first Temurin listing (matches Dockerfile behavior)
      chosen_candidate=$(printf '%s\n' "$sdk_list" | grep -- "-tem" | cut -d '|' -f 6 | tr -d ' ' | head -n1 || true)
      echo "java-devtools: requested 'latest' -> chosen candidate: ${chosen_candidate}"
    elif [[ "${JDK_VERSION}" == "ea" || "${JDK_VERSION}" == "early-access" ]]; then
      # Pick an Early Access build (open builds often have .ea. in the identifier)
      chosen_candidate=$(printf '%s\n' "$sdk_list" | grep -E "\.ea\." | cut -d '|' -f 6 | tr -d ' ' | head -n1 || true)
      echo "java-devtools: requested 'ea' -> chosen candidate: ${chosen_candidate}"
    else
      # Filter candidates that start with the requested major (e.g. 21 or 21.)
      matching=$(printf '%s\n' "$candidates" | grep -E "^${JDK_VERSION}([.-]|$)" || true)
      if [[ -n "$matching" ]]; then
        # Normalize (remove -tem suffix), semver-sort and pick the highest patch, then re-append '-tem'
        normalized=$(printf '%s\n' "$matching" | sed 's/-tem$//' | sort -V | tail -n1 || true)
        if [[ -n "$normalized" ]]; then
          chosen_candidate="${normalized}-tem"
          echo "java-devtools: selected Temurin candidate: ${chosen_candidate}"
        fi
      fi
    fi
  fi

  if [[ -n "$chosen_candidate" ]]; then
    echo "java-devtools: installing chosen Temurin candidate via sdk: ${chosen_candidate}"
    set +u; sdk install java "$chosen_candidate" || true; set -u
  else
    echo "java-devtools: no suitable Temurin candidate found for major ${JDK_VERSION}; falling back to tolerant installs" >&2
    # Try a small sequence of common identifiers as a fallback
    set +u
    sdk install java "${JDK_VERSION}" || \
      sdk install java "temurin-${JDK_VERSION}" || \
      sdk install java "openjdk-${JDK_VERSION}" || \
      sdk install java "${JDK_VERSION}.0.0-tem" || true
    set -u
  fi

  if command -v java >/dev/null 2>&1; then
    echo "java-devtools: java available after sdk install"
  else
    echo "java-devtools: java not available after sdk install attempts" >&2
  fi
else
  echo "java-devtools: sdk not available to install JDK ${JDK_VERSION}" >&2
fi

if [ "$INSTALL_MAVEN" = "true" ]; then
  if command -v mvn >/dev/null 2>&1; then
    echo "maven already installed"
  else
    if ! command -v sdk >/dev/null 2>&1; then
      echo "java-devtools: SDKMAN not available; please enable SDKMAN in base image to install Maven" >&2
    else
      echo "java-devtools: installing Maven via SDKMAN"
      set +u; sdk install maven || true; set -u
    fi
  fi
fi

if [ "$INSTALL_GRADLE" = "true" ]; then
  if command -v gradle >/dev/null 2>&1; then
    echo "gradle already installed"
  else
    if ! command -v sdk >/dev/null 2>&1; then
      echo "java-devtools: SDKMAN not available; please enable SDKMAN in base image to install Gradle" >&2
    else
      echo "java-devtools: installing Gradle via SDKMAN"
      set +u; sdk install gradle || true; set -u
    fi
  fi
fi

if [ "$INSTALL_JDTLS" = "true" ]; then
  echo "java-devtools: installing jdtls (language server)"
  # placeholder: installation steps depend on distribution; prefer downloading release
  echo "Please configure JDTLS download URL via ARTIFACTS_BASE_URL or system package manager"
fi

echo "java-devtools: done"

ensure_sdkman_init() {
  # If sdk exists, ensure non-interactive shells source sdkman init
  if command -v sdk >/dev/null 2>&1; then
    SDKMAN_DIR=${SDKMAN_DIR:-"$HOME/.sdkman"}
    INIT_SH="$SDKMAN_DIR/bin/sdkman-init.sh"
    if [[ -f "$INIT_SH" ]]; then
      # Ensure user's zshenv sources sdkman init for non-interactive shells
      if [[ -w "$HOME" ]]; then
        ZSHENV_FILE="$HOME/.zshenv"
        if ! grep -q "sdkman-init.sh" "$ZSHENV_FILE" 2>/dev/null; then
          echo "# SDKMAN initialization" >> "$ZSHENV_FILE" || true
          echo "export SDKMAN_DIR=\"$SDKMAN_DIR\"" >> "$ZSHENV_FILE" || true
          echo '[[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]] && source "$HOME/.sdkman/bin/sdkman-init.sh"' >> "$ZSHENV_FILE" || true
          echo "java-devtools: added SDKMAN init to $ZSHENV_FILE"
        fi
      fi
      # Also add a system-wide profile.d script if possible so /bin/sh non-interactive shells pick it up
      if [[ -d /etc/profile.d && -w /etc/profile.d ]]; then
        cat > /etc/profile.d/sdkman.sh <<'EOF' || true
#!/usr/bin/env sh
if [ -n "${SDKMAN_DIR-}" ]; then
  if [ -s "${SDKMAN_DIR}/bin/sdkman-init.sh" ]; then
    # shellcheck disable=SC1090
    . "${SDKMAN_DIR}/bin/sdkman-init.sh"
  fi
fi
EOF
        chmod 644 /etc/profile.d/sdkman.sh || true
        echo "java-devtools: wrote /etc/profile.d/sdkman.sh"
      fi
    fi
  fi
}

echo "User: $(whoami)"

ensure_sdkman_init
