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

# Install Gradle via SDKMAN.
#
# `sdk install gradle` is a build-time network fetch through the SDKMAN that
# the java-sdkman feature installs. It used to end in `|| true`, so a failed
# fetch left the leg green with no gradle in it while feature.json advertised
# `gradle`. Fail at the point of failure and name the producer.
if [ -n "${GRADLE_VERSION}" ]; then
  echo "java-gradle: installing Gradle version ${GRADLE_VERSION} via SDKMAN"
  GRADLE_SDK_CMD="sdk install gradle ${GRADLE_VERSION}"
else
  echo "java-gradle: installing latest Gradle via SDKMAN"
  GRADLE_SDK_CMD="sdk install gradle"
fi
if ! su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; ${GRADLE_SDK_CMD}"; then
  echo "❌ java-gradle: FH_JAVA_GRADLE_INSTALL_FAILED — '${GRADLE_SDK_CMD}' failed for user ${NB_USER:-jovyan}. This stage performs a build-time network fetch through the SDKMAN installed by the java-sdkman feature; aborting rather than publishing an image that advertises gradle and ships none." >&2
  exit 1
fi

# Verify installation: the post-condition for the install above.
if su - ${NB_USER:-jovyan} -s /bin/bash -lc 'command -v gradle >/dev/null 2>&1'; then
  echo "java-gradle: installation successful"
  su - ${NB_USER:-jovyan} -s /bin/bash -lc 'gradle --version' || true
else
  echo "❌ java-gradle: FH_JAVA_GRADLE_NOT_AVAILABLE — 'gradle' does not resolve for ${NB_USER:-jovyan} even though '${GRADLE_SDK_CMD}' exited 0. Nothing upstream failed loudly: the java-sdkman feature produced the 'sdk' that reported success, and ~/.sdkman/candidates/gradle is the artefact that is missing. Aborting rather than publishing an image that advertises gradle and ships none." >&2
  exit 1
fi

echo "java-gradle: done"
