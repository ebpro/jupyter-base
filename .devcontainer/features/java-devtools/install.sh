#!/usr/bin/env bash
set -euo pipefail

# java-devtools install
# New options added: INSTALL_SDKMAN, INSTALL_JAVA_LTS, INSTALL_JAVA_LATEST, JAVA_LTS_REGEX, INSTALL_GRAAL
INSTALL_MAVEN=${INSTALL_MAVEN:-true}
INSTALL_GRADLE=${INSTALL_GRADLE:-false}
INSTALL_JDTLS=${INSTALL_JDTLS:-false}
INSTALL_SDKMAN=${INSTALL_SDKMAN:-true}
INSTALL_JAVA_LTS=${INSTALL_JAVA_LTS:-true}
INSTALL_JAVA_LATEST=${INSTALL_JAVA_LATEST:-false}
JAVA_LTS_REGEX=${JAVA_LTS_REGEX:-"^21\\|^25"}
INSTALL_GRAAL=${INSTALL_GRAAL:-false}

NB_USER=${NB_USER:-jovyan}
HOME_DIR=${HOME_DIR:-/home/${NB_USER}}

echo "java-devtools: maven=$INSTALL_MAVEN gradle=$INSTALL_GRADLE jdtls=$INSTALL_JDTLS sdkman=$INSTALL_SDKMAN java_lts=$INSTALL_JAVA_LTS java_latest=$INSTALL_JAVA_LATEST graal=$INSTALL_GRAAL"

run_as_user() {
  # Run commands as NB_USER where possible
  if [ "$(id -u)" -eq 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
      sudo -H -u "${NB_USER}" bash -lc "$1"
    else
      su - "${NB_USER}" -c "$1"
    fi
  else
    bash -lc "$1"
  fi
}

install_sdkman() {
  if [ -d "${HOME_DIR}/.sdkman" ]; then
    echo "java-devtools: SDKMAN already installed in ${HOME_DIR}/.sdkman"
    return 0
  fi
  echo "java-devtools: installing SDKMAN for ${NB_USER}"
  run_as_user "curl -s https://get.sdkman.io | bash && echo 'sdkman_auto_answer=true' > '${HOME_DIR}/.sdkman/etc/config' || true"
  # ensure SDKMAN env available for subsequent commands in this script when run_as_user
}

install_java_versions() {
  local mode="$1"
  # mode: lts|latest|graal
  if ! run_as_user "command -v sdk >/dev/null 2>&1"; then
    echo "java-devtools: sdk not found in user environment; SDKMAN install may have failed" >&2
    return 1
  fi

  if [ "$mode" = "latest" ]; then
    echo "java-devtools: installing latest Java via SDKMAN"
    run_as_user "JAVA_LATEST=\$(sdk list java | grep -- '-tem' | cut -d '|' -f 6 | head -n 1 | tr -d ' ') && sdk install java \"\$JAVA_LATEST\" || true"
  elif [ "$mode" = "lts" ]; then
    echo "java-devtools: installing LTS Java versions via SDKMAN (regex=${JAVA_LTS_REGEX})"
    run_as_user "for version in \$(sdk list java | tr -s ' ' | grep ' tem ' | cut -d '|' -f 6 | tr -d ' ' | sed 's/\(^[^\.-]*\)\(.*\)$/\1,\1\2/' | sort -u -t, -k 1,1 | cut -f 2 -d, | grep -E \"${JAVA_LTS_REGEX}\"); do echo Installing \$version; sdk install java \"\$version\" || true; done"
  elif [ "$mode" = "graal" ]; then
    echo "java-devtools: installing GraalVM via SDKMAN"
    run_as_user "GRAAL_VERSION=\$(sdk list java | tr -d ' ' | grep '-graal$' | grep -v '\\.ea\\.' | cut -d '|' -f 6 | head -n 1) && [ -n \"\$GRAAL_VERSION\" ] && sdk install java \"\$GRAAL_VERSION\" || true"
  fi
}

# Install SDKMAN if requested
if [ "${INSTALL_SDKMAN}" = "true" ]; then
  install_sdkman || true
fi

# Install Java LTS and/or latest as requested
if [ "${INSTALL_JAVA_LTS}" = "true" ]; then
  install_java_versions lts || true
fi
if [ "${INSTALL_JAVA_LATEST}" = "true" ]; then
  install_java_versions latest || true
fi
if [ "${INSTALL_GRAAL}" = "true" ]; then
  install_java_versions graal || true
fi

# Install Maven/Gradle/JDTLS as before, prefer SDKMAN-installed versions
if [ "${INSTALL_MAVEN}" = "true" ]; then
  if run_as_user "command -v mvn >/dev/null 2>&1"; then
    echo "maven already installed for ${NB_USER}"
  else
    if ! run_as_user "command -v sdk >/dev/null 2>&1"; then
      echo "java-devtools: SDKMAN not available; cannot install Maven for ${NB_USER}" >&2
    else
      echo "java-devtools: installing Maven via SDKMAN for ${NB_USER}"
      run_as_user "sdk install maven || true"
    fi
  fi
fi

if [ "${INSTALL_GRADLE}" = "true" ]; then
  if run_as_user "command -v gradle >/dev/null 2>&1"; then
    echo "gradle already installed for ${NB_USER}"
  else
    if ! run_as_user "command -v sdk >/dev/null 2>&1"; then
      echo "java-devtools: SDKMAN not available; cannot install Gradle for ${NB_USER}" >&2
    else
      echo "java-devtools: installing Gradle via SDKMAN for ${NB_USER}"
      run_as_user "sdk install gradle || true"
    fi
  fi
fi

if [ "${INSTALL_JDTLS}" = "true" ]; then
  echo "java-devtools: installing jdtls (language server)"
  echo "Please configure JDTLS download URL via ARTIFACTS_BASE_URL or system package manager"
fi

echo "java-devtools: done"
