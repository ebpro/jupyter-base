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

# Install Maven via SDKMAN.
#
# `sdk install maven` is a build-time network fetch through the SDKMAN that
# the java-sdkman feature installs. It used to end in `|| true`, so a failed
# fetch left the leg green with no mvn in it while feature.json advertised
# `maven`/`mvn`. Fail at the point of failure and name the producer.
if [ -n "${MAVEN_VERSION}" ]; then
  echo "java-maven: installing Maven version ${MAVEN_VERSION} via SDKMAN"
  MAVEN_SDK_CMD="sdk install maven ${MAVEN_VERSION}"
else
  echo "java-maven: installing latest Maven via SDKMAN"
  MAVEN_SDK_CMD="sdk install maven"
fi
if ! su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; ${MAVEN_SDK_CMD}"; then
  echo "❌ java-maven: FH_JAVA_MAVEN_INSTALL_FAILED — '${MAVEN_SDK_CMD}' failed for user ${NB_USER:-jovyan}. This stage performs a build-time network fetch through the SDKMAN installed by the java-sdkman feature; aborting rather than publishing an image that advertises mvn and ships none." >&2
  exit 1
fi

# Verify installation: the post-condition for the install above.
if su - ${NB_USER:-jovyan} -s /bin/bash -lc 'command -v mvn >/dev/null 2>&1'; then
  echo "java-maven: installation successful"
  su - ${NB_USER:-jovyan} -s /bin/bash -lc 'mvn --version' || true
else
  echo "❌ java-maven: FH_JAVA_MAVEN_NOT_AVAILABLE — 'mvn' does not resolve for ${NB_USER:-jovyan} even though '${MAVEN_SDK_CMD}' exited 0. Nothing upstream failed loudly: the java-sdkman feature produced the 'sdk' that reported success, and ~/.sdkman/candidates/maven is the artefact that is missing. Aborting rather than publishing an image that advertises mvn and ships none." >&2
  exit 1
fi

echo "java-maven: done"
