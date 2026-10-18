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
#
# `gradle` is reachable only through $HOME/.sdkman/candidates/gradle/current/bin,
# which sdkman-init.sh exports. A bare login shell does NOT have it at this
# stage of the build: /etc/profile.d/solen.sh, the hook that would export the
# SDKMAN paths, is written by the RUN that comes AFTER the feature loop
# (solen-cli/solen/generators/dockerfile_template.j2:240-243), and `su -`
# resets PATH through /etc/profile. So a probe that only runs `command -v`
# in a login shell can never pass, even on a healthy install. Evaluate the
# post-condition the way the consumers evaluate it at runtime: source the
# init script, then verify the artefact and its resolvability, with distinct
# exit statuses per broken guarantee.
gradle_probe_rc=0
su - ${NB_USER:-jovyan} -s /bin/bash -lc 'set +u; [ -s "$HOME/.sdkman/bin/sdkman-init.sh" ] || exit 3; source "$HOME/.sdkman/bin/sdkman-init.sh" >/dev/null 2>&1 || exit 4; [ -x "$HOME/.sdkman/candidates/gradle/current/bin/gradle" ] || exit 6; command -v gradle >/dev/null 2>&1 || exit 5' || gradle_probe_rc=$?
if [ "$gradle_probe_rc" -ne 0 ]; then
  case "$gradle_probe_rc" in
    3) cause="no init artefact at \$HOME/.sdkman/bin/sdkman-init.sh for ${NB_USER:-jovyan}" ;;
    4) cause="sdkman-init.sh could not be sourced by ${NB_USER:-jovyan}" ;;
    6) cause="the artefact \$HOME/.sdkman/candidates/gradle/current/bin/gradle is missing for ${NB_USER:-jovyan}" ;;
    5) cause="'gradle' is not resolvable for ${NB_USER:-jovyan} even after sourcing sdkman-init.sh" ;;
    *) cause="the gradle probe for ${NB_USER:-jovyan} could not be executed (exit ${gradle_probe_rc})" ;;
  esac
  echo "❌ java-gradle: FH_JAVA_GRADLE_NOT_AVAILABLE — ${cause} although '${GRADLE_SDK_CMD}' exited 0. Aborting rather than publishing an image that advertises gradle and ships none." >&2
  exit 1
fi
echo "java-gradle: installation successful"
su - ${NB_USER:-jovyan} -s /bin/bash -lc 'gradle --version' || true

echo "java-gradle: done"
