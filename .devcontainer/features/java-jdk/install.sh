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

# Helper: query SDKMAN list for a matching candidate (run as NB_USER)
query_candidate() {
  local pattern="$1"
  su - ${NB_USER:-jovyan} -s /bin/bash -lc \
    "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; sdk list java | grep -E \"${pattern}\" | awk '{print \$NF}' | head -n1" || true
}

# Install JDK based on version specification
install_jdk() {
  local ver="$1"
  local dist_id="$2"
  local cand

  # Case 1: 'default' - let SDKMAN pick
  if [ -z "${ver}" ] || [ "${ver}" = "default" ]; then
    echo "java-jdk: installing default java via sdk"
    su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; sdk install java" || true
    return 0
  fi

  # Case 2: 'ea' - latest Early Access
  if [ "${ver}" = "ea" ]; then
    echo "java-jdk: selecting latest openjdk EA via SDKMAN"
    cand=$(query_candidate "openjdk.*ea|openjdk.*-ea") || true
    if [ -n "${cand}" ]; then
      su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; sdk install java ${cand}" || true
    else
      echo "java-jdk: no openjdk EA candidate found; falling back to default"
      su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; sdk install java" || true
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
      su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; sdk install java ${cand}" || true
    else
      echo "java-jdk: no ${dist_id} candidate found; falling back to default"
      su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; sdk install java" || true
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
      su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; sdk install java ${cand}" || true
    else
      echo "java-jdk: no matching ${dist_id} candidate for version ${ver}; trying default"
      su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; sdk install java" || true
    fi
    return 0
  fi

  # Case 5: Specific identifier (e.g., "17.0.9-tem")
  echo "java-jdk: installing specific identifier: ${ver}"
  su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; sdk install java ${ver}" || true
}

# Run installation
install_jdk "${JDK_VERSION}" "${SDKMAN_JAVA_IDENTIFIER}"

# Verify installation
if su - ${NB_USER:-jovyan} -s /bin/bash -lc 'java -version >/dev/null 2>&1'; then
  echo "java-jdk: installation successful"
  su - ${NB_USER:-jovyan} -s /bin/bash -lc 'java -version' || true
else
  echo "java-jdk: WARNING - java command not available after installation" >&2
fi

echo "java-jdk: done"
