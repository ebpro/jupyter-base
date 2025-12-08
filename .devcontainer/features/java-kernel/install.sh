#!/usr/bin/env bash
set -euo pipefail

# java-kernel install.sh
# Installs a Java kernel (IJava) either by downloading a release tarball or building from a submodule.
# It prefers to use repository Artefacts and centralized checksum helpers when available.

# Source shared feature helpers when available (same pattern as other features)
if [ -n "${FEATURE_HELPERS_DIR:-}" ] && [ -f "${FEATURE_HELPERS_DIR}/helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "${FEATURE_HELPERS_DIR}/helpers.sh"
elif [ -f "../../../scripts/feature_helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "../../../scripts/feature_helpers.sh"
fi

KERNEL_SOURCE=${KERNEL_SOURCE:-${1:-${kernel_source:-release}}}
KERNEL_VERSION=${KERNEL_VERSION:-${2:-${kernel_version:-}}}
JDK_VERSION=${JDK_VERSION:-${3:-${jdk_version:-17}}}

NB_USER=${NB_USER:-jovyan}
NB_UID=${NB_UID:-1001}
NB_GID=${NB_GID:-1001}
HOME_DIR="/home/${NB_USER}"

fh_log "java-kernel: source=${KERNEL_SOURCE} version=${KERNEL_VERSION} jdk=${JDK_VERSION}"

install_jdk() {
  local ver="$1"
  local dist_id="${SDKMAN_JAVA_IDENTIFIER:-temurin}"
  fh_log "java-kernel: ensuring JDK (sdkman candidate=${dist_id}) version=${ver}"
  # Try to make sdk (SDKMAN) available if possible
  if ! command -v sdk >/dev/null 2>&1; then
    if [ -n "${SDKMAN_DIR:-}" ] && [ -f "${SDKMAN_DIR}/bin/sdkman-init.sh" ]; then
      # shellcheck disable=SC1091
      source "${SDKMAN_DIR}/bin/sdkman-init.sh"
    elif [ -f "${HOME_DIR}/.sdkman/bin/sdkman-init.sh" ]; then
      # shellcheck disable=SC1091
      source "${HOME_DIR}/.sdkman/bin/sdkman-init.sh"
    fi
  fi

  if ! command -v sdk >/dev/null 2>&1; then
    fh_log "java-kernel: sdk (SDKMAN) not available; skipping automatic JDK install"
    return 1
  fi

  local cand
  if [ -n "$ver" ]; then
    cand="${dist_id}-${ver}"
  else
    cand="$dist_id"
  fi
  fh_log "java-kernel: running: sdk install java ${cand}"
  sdk install java "${cand}" || sdk install java "${dist_id}" || true
}

render_kernelspec() {
  local dest_dir="$1" jarpath="$2"
  mkdir -p "$dest_dir"
  cat > "$dest_dir/kernel.json" <<EOF
{
  "argv": ["java", "-ea", "--enable-preview", "-jar", "$jarpath", "{connection_file}"],
  "display_name": "Java",
  "language": "java"
}
EOF
}

is_root() { [ "$(id -u)" -eq 0 ]; }

kernel_install_dest() {
  if is_root; then
    echo "/usr/local/share/jupyter/kernels/java"
  else
    echo "${HOME_DIR}/.local/share/jupyter/kernels/java"
  fi
}

install_from_release() {
  local base_url=${ARTIFACTS_BASE_URL:-}
  local url=${ARTEFACT_URL:-}
  if [ -z "${KERNEL_VERSION}" ] && command -v jq >/dev/null 2>&1 && [ -f "${PWD}/Artefacts/versions.json" ]; then
    KERNEL_VERSION=$(jq -r '.tools["java-kernel"] // empty' "${PWD}/Artefacts/versions.json" 2>/dev/null || true)
  fi
  if [ -n "${KERNEL_VERSION}" ]; then
    if [ -z "$url" ] && [ -n "$base_url" ]; then
      url="$base_url/java-kernel-${KERNEL_VERSION}.tar.gz"
    fi
  fi
  if [ -z "$url" ]; then
    fh_log "java-kernel: no release URL available (set ARTEFACT_URL or ARTIFACTS_BASE_URL+kernel_version)"
    return 1
  fi

  local tmpdir
  tmpdir=$(mktemp -d)
  trap 'rm -rf "${tmpdir}"' EXIT

  fh_log "java-kernel: downloading ${url}"
  if command -v toolcache-get >/dev/null 2>&1; then
    # try toolcache-get to reuse cached downloads
    prefix=$(toolcache-get "java-kernel" "${KERNEL_VERSION}" "${url}" "" || true)
    if [ -n "${prefix}" ] && [ -f "${prefix}/$(basename "${url}")" ]; then
      cp -a "${prefix}/$(basename "${url}")" "${tmpdir}/kernel.tar.gz"
    fi
  fi
  if [ ! -f "${tmpdir}/kernel.tar.gz" ]; then
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL -o "${tmpdir}/kernel.tar.gz" "${url}"
    else
      fh_log "java-kernel: curl not available"; return 1
    fi
  fi

  # verify checksum when available
  if command -v fh_verify_from_checksums >/dev/null 2>&1; then
    fh_verify_from_checksums "java-kernel" "${KERNEL_VERSION}" "${TARGETARCH:-amd64}" "${tmpdir}/kernel.tar.gz" || fh_log "java-kernel: checksum verification failed (continuing)"
  elif command -v verify-artifact >/dev/null 2>&1; then
    CHKSUM=""
    if [ -f "${PWD}/Artefacts/checksums.json" ]; then
      CHKSUM=$(jq -r --arg t "java-kernel" --arg v "${KERNEL_VERSION}" --arg a "${TARGETARCH:-amd64}" '.tools[$t].checksums[$v][$a] // empty' "${PWD}/Artefacts/checksums.json" 2>/dev/null || true)
    fi
    if [ -z "${CHKSUM}" ] && [ -f /tmp/checksums.json ]; then
      CHKSUM=$(jq -r --arg t "java-kernel" --arg v "${KERNEL_VERSION}" --arg a "${TARGETARCH:-amd64}" '.tools[$t].checksums[$v][$a] // empty' /tmp/checksums.json 2>/dev/null || true)
    fi
    if [ -n "${CHKSUM}" ]; then
      verify-artifact "${CHKSUM}" "${tmpdir}/kernel.tar.gz" || fh_log "java-kernel: checksum failed"
    fi
  fi

  tar -xzf "${tmpdir}/kernel.tar.gz" -C "${tmpdir}"
  local jar
  jar=$(find "${tmpdir}" -type f -name "*ijava*.jar" -o -name "*kernel*.jar" | head -n1 || true)
  if [ -z "${jar}" ]; then
    jar=$(find "${tmpdir}" -type f -name "*.jar" | head -n1 || true)
  fi
  if [ -z "${jar}" ]; then
    fh_log "java-kernel: could not find kernel jar inside release"
    return 1
  fi

  local dest
  dest=$(kernel_install_dest)
  mkdir -p "${dest}"
  cp "${jar}" "${dest}/ijava.jar"
  render_kernelspec "${dest}" "${dest}/ijava.jar"
  chown -R "${NB_UID}":"${NB_GID}" "${dest}" || true
  fh_log "java-kernel: installed kernelspec at ${dest}"
}

install_from_submodule() {
  if [ ! -d "./submodules/java-kernel" ]; then
    fh_log "java-kernel: submodule not present at ./submodules/java-kernel"
    return 1
  fi
  pushd ./submodules/java-kernel >/dev/null
  local jar
  if [ -f mvnw ]; then
    ./mvnw -DskipTests package
    jar=$(find target -type f -name "*ijava*.jar" | head -n1 || true)
  elif [ -f gradlew ]; then
    ./gradlew assemble
    jar=$(find build -type f -name "*ijava*.jar" | head -n1 || true)
  else
    fh_log "java-kernel: no mvnw or gradlew found in submodule"
    popd >/dev/null
    return 1
  fi
  popd >/dev/null

  if [ -z "${jar}" ]; then
    fh_log "java-kernel: failed to build kernel jar"
    return 1
  fi

  local dest
  dest=$(kernel_install_dest)
  mkdir -p "${dest}"
  cp "${jar}" "${dest}/ijava.jar"
  render_kernelspec "${dest}" "${dest}/ijava.jar"
  chown -R "${NB_UID}":"${NB_GID}" "${dest}" || true
  fh_log "java-kernel: installed kernelspec at ${dest} (built from submodule)"
}

# Main
install_jdk "${JDK_VERSION}" || true
if [[ "${KERNEL_SOURCE}" = "release" ]]; then
  install_from_release
else
  install_from_submodule
fi

fh_log "java-kernel: done"
