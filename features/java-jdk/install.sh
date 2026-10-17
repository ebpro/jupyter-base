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

# java-jdk install - JDK installation via SDKMAN
JDK_VERSION=${JDK_VERSION:-25}
SDKMAN_JAVA_IDENTIFIER=${SDKMAN_JAVA_IDENTIFIER:-temurin}

echo "java-jdk: installing JDK version=${JDK_VERSION} distribution=${SDKMAN_JAVA_IDENTIFIER}"

# Verify SDKMAN is available
if ! command -v sdk >/dev/null 2>&1; then
  # Try to source SDKMAN init
  if [ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]; then
    set +u
    # shellcheck source=/dev/null
    source "$HOME/.sdkman/bin/sdkman-init.sh"
    set -u
  else
    echo "java-jdk: ERROR - SDKMAN not available. Please include java-sdkman feature first." >&2
    exit 1
  fi
fi

# Helper: query SDKMAN list for a matching candidate (run as NB_USER).
# Candidate DISCOVERY is allowed to come back empty (each caller has a
# documented fallback below), but a missing candidate never becomes a green
# build: the install that follows is verified and fatal on failure.
query_candidate() {
  local pattern="$1"
  su - ${NB_USER:-jovyan} -s /bin/bash -lc \
    "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; sdk list java | grep -E \"${pattern}\" | awk '{print \$NF}' | head -n1" || true
}

# Run one `sdk install java …` as the target user, failing loudly.
#
# `sdk install java` is a build-time network fetch (SDK CDN + the vendor's
# archive). It used to end in `|| true`, so when the fetch failed the
# installer printed the upstream refusal and kept going: CI run 39053927880
# (arm64) shipped
#   "Download has failed, aborting!" / "Can not install java <ver> at this
#    time..."  →  "java-jdk: WARNING - java command not available"  →  done,
# and the leg still went green. Fail at the point of failure, naming the
# producer (java-sdkman supplies `sdk`) so the blame cannot drift.
run_sdk_install() {
  local sdk_cmd="$1"
  if ! su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; ${sdk_cmd}"; then
    echo "❌ java-jdk: FH_JAVA_JDK_INSTALL_FAILED — '${sdk_cmd}' failed for user ${NB_USER:-jovyan}. This stage performs a build-time network fetch through the SDKMAN installed by the java-sdkman feature; aborting rather than publishing an image with no JDK in it." >&2
    exit 1
  fi
}

# Install JDK based on version specification
install_jdk() {
  local ver="$1"
  local dist_id="$2"
  local cand

  # Case 1: 'default' - let SDKMAN pick
  if [ -z "${ver}" ] || [ "${ver}" = "default" ]; then
    echo "java-jdk: installing default java via sdk"
    run_sdk_install "sdk install java"
    return 0
  fi

  # Case 2: 'ea' - latest Early Access
  if [ "${ver}" = "ea" ]; then
    echo "java-jdk: selecting latest openjdk EA via SDKMAN"
    cand=$(query_candidate "openjdk.*ea|openjdk.*-ea") || true
    if [ -n "${cand}" ]; then
      run_sdk_install "sdk install java ${cand}"
    else
      echo "java-jdk: no openjdk EA candidate found; falling back to default"
      run_sdk_install "sdk install java"
    fi
    return 0
  fi

  # Case 3: 'latest' - latest stable from specified distribution
  if [ "${ver}" = "latest" ]; then
    echo "java-jdk: selecting latest ${dist_id} candidate via SDKMAN"
    # Look for candidates ending with distribution suffix (e.g., -tem for temurin)
    local suffix=""
    case "${dist_id}" in
      temurin) suffix="-tem" ;;
      openjdk) suffix=".*" ;;
      oracle) suffix="-oracle" ;;
      *) suffix=".*" ;;
    esac

    cand=$(su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; sdk list java | tr -d ' ' | cut -f 6 -d '|' | grep \"${suffix}\$\" | head -n1") || true

    if [ -n "${cand}" ]; then
      run_sdk_install "sdk install java ${cand}"
    else
      echo "java-jdk: no ${dist_id} candidate found; falling back to default"
      run_sdk_install "sdk install java"
    fi
    return 0
  fi

  # Case 4: Numeric major version (8, 11, 17, 21, 25, etc.)
  if echo "${ver}" | grep -Eq '^[0-9]+$'; then
    echo "java-jdk: selecting ${dist_id} version ${ver} via SDKMAN"
    local suffix=""
    case "${dist_id}" in
      temurin) suffix="-tem" ;;
      openjdk) suffix=".*" ;;
      oracle) suffix="-oracle" ;;
      *) suffix=".*" ;;
    esac

    cand=$(su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; sdk list java | tr -d ' ' | cut -f 6 -d '|' | grep \"^${ver}\\..*${suffix}\" | head -n1") || true

    if [ -n "${cand}" ]; then
      run_sdk_install "sdk install java ${cand}"
    else
      echo "java-jdk: no matching ${dist_id} candidate for version ${ver}; trying default"
      run_sdk_install "sdk install java"
    fi
    return 0
  fi

  # Case 5: Specific identifier (e.g., "17.0.9-tem")
  echo "java-jdk: installing specific identifier: ${ver}"
  run_sdk_install "sdk install java ${ver}"
}

# Run installation
install_jdk "${JDK_VERSION}" "${SDKMAN_JAVA_IDENTIFIER}"

# Verify installation. This is the post-condition for every branch above: a
# JDK the target user cannot execute is a failed feature, not a warning —
# `provides: [java, javac]` is a promise the published image has to keep.
if su - ${NB_USER:-jovyan} -s /bin/bash -lc 'command -v java >/dev/null 2>&1 && java -version >/dev/null 2>&1'; then
  echo "java-jdk: installation successful"
  su - ${NB_USER:-jovyan} -s /bin/bash -lc 'java -version' || true
else
  echo "❌ java-jdk: FH_JAVA_JDK_NOT_AVAILABLE — 'java' does not resolve for ${NB_USER:-jovyan} after installation (candidate dir ${SDKMAN_JAVA_IDENTIFIER:-temurin}, version request ${JDK_VERSION}). The java-sdkman feature is the producer of 'sdk'; the sdkman-init.sh under \${NB_USER}'s home and ~/.sdkman/candidates/java are the artefacts to inspect. Aborting rather than publishing an image that advertises java/javac and ships neither." >&2
  exit 1
fi

echo "java-jdk: done"
