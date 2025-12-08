#!/usr/bin/env bash
set -euo pipefail

# java-devtools install
INSTALL_MAVEN=${INSTALL_MAVEN:-true}
INSTALL_GRADLE=${INSTALL_GRADLE:-false}
INSTALL_JDTLS=${INSTALL_JDTLS:-false}

echo "java-devtools: maven=$INSTALL_MAVEN gradle=$INSTALL_GRADLE jdtls=$INSTALL_JDTLS"

if [ "$INSTALL_MAVEN" = "true" ]; then
  if command -v mvn >/dev/null 2>&1; then
    echo "maven already installed"
  else
    if ! command -v sdk >/dev/null 2>&1; then
      echo "java-devtools: SDKMAN not available; please enable SDKMAN in base image to install Maven" >&2
    else
      echo "java-devtools: installing Maven via SDKMAN"
      sdk install maven || true
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
      sdk install gradle || true
    fi
  fi
fi

if [ "$INSTALL_JDTLS" = "true" ]; then
  echo "java-devtools: installing jdtls (language server)"
  # placeholder: installation steps depend on distribution; prefer downloading release
  echo "Please configure JDTLS download URL via ARTIFACTS_BASE_URL or system package manager"
fi

echo "java-devtools: done"
