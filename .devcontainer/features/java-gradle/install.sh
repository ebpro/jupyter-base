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

# java-gradle install - Gradle build tool via SDKMAN
GRADLE_VERSION=${GRADLE_VERSION:-}

echo "java-gradle: installing Gradle${GRADLE_VERSION:+ version ${GRADLE_VERSION}}"

# Check if Gradle already installed
if command -v gradle >/dev/null 2>&1; then
  echo "java-gradle: Gradle already installed"
  gradle --version || true
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
    echo "java-gradle: ERROR - SDKMAN not available. Please include java-sdkman feature first." >&2
    exit 1
  fi
fi

# Install Gradle via SDKMAN
if [ -n "${GRADLE_VERSION}" ]; then
  echo "java-gradle: installing Gradle version ${GRADLE_VERSION} via SDKMAN"
  su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; sdk install gradle ${GRADLE_VERSION}" || true
else
  echo "java-gradle: installing latest Gradle via SDKMAN"
  su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; sdk install gradle" || true
fi

# Verify installation
if su - ${NB_USER:-jovyan} -s /bin/bash -lc 'command -v gradle >/dev/null 2>&1'; then
  echo "java-gradle: installation successful"
  su - ${NB_USER:-jovyan} -s /bin/bash -lc 'gradle --version' || true
else
  echo "java-gradle: WARNING - gradle command not available after installation" >&2
fi

echo "java-gradle: done"
