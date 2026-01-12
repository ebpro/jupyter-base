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

# java-maven install - Maven build tool via SDKMAN
MAVEN_VERSION=${MAVEN_VERSION:-}

echo "java-maven: installing Maven${MAVEN_VERSION:+ version ${MAVEN_VERSION}}"

# Check if Maven already installed
if command -v mvn >/dev/null 2>&1; then
  echo "java-maven: Maven already installed"
  mvn --version || true
  exit 0
fi

# Verify SDKMAN is available
if ! command -v sdk >/dev/null 2>&1; then
  # Try to source SDKMAN init
  if [ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]; then
    set +u
    # shellcheck disable=SC1091
    source "$HOME/.sdkman/bin/sdkman-init.sh"
    set -u
  else
    echo "java-maven: ERROR - SDKMAN not available. Please include java-sdkman feature first." >&2
    exit 1
  fi
fi

# Install Maven via SDKMAN
if [ -n "${MAVEN_VERSION}" ]; then
  echo "java-maven: installing Maven version ${MAVEN_VERSION} via SDKMAN"
  su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; sdk install maven ${MAVEN_VERSION}" || true
else
  echo "java-maven: installing latest Maven via SDKMAN"
  su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; sdk install maven" || true
fi

# Verify installation
if su - ${NB_USER:-jovyan} -s /bin/bash -lc 'command -v mvn >/dev/null 2>&1'; then
  echo "java-maven: installation successful"
  su - ${NB_USER:-jovyan} -s /bin/bash -lc 'mvn --version' || true
else
  echo "java-maven: WARNING - mvn command not available after installation" >&2
fi

echo "java-maven: done"
