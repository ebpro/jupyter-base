#!/usr/bin/env bash
set -euo pipefail

# java-kernel install.sh
# Installs a Java kernel (IJava) either by downloading a release tarball or building from a submodule.
# Relies on ARTIFACTS_BASE_URL / ARTEFACT_URL or presence of a submodule at ./submodules/java-kernel

KERNEL_SOURCE=${KERNEL_SOURCE:-${1:-${kernel_source:-release}}}
KERNEL_VERSION=${KERNEL_VERSION:-${2:-${kernel_version:-}}}
JDK_VERSION=${JDK_VERSION:-${3:-${jdk_version:-17}}}

echo "java-kernel: source=${KERNEL_SOURCE} version=${KERNEL_VERSION} jdk=${JDK_VERSION}"

install_jdk() {
  local ver="$1"
  # Use SDKMAN only. Default distribution is Temurin unless overridden by SDKMAN_JAVA_IDENTIFIER
  local dist_id="${SDKMAN_JAVA_IDENTIFIER:-temurin}"
  echo "java-kernel: ensuring JDK (sdkman candidate=${dist_id}) version=${ver}" 
  if ! command -v sdk >/dev/null 2>&1; then
    echo "java-kernel: sdk (SDKMAN) not available. Please enable SDKMAN in your base image or devcontainer." >&2
    return 1
  fi
  local cand
  if [ -n "$ver" ]; then
    cand="${dist_id}-${ver}"
  else
    cand="$dist_id"
  fi
  echo "java-kernel: running: sdk install java ${cand}"
  sdk install java "${cand}" || sdk install java "${dist_id}" || true
}

render_kernelspec() {
  local dest_dir="$1" jarpath="$2"
  mkdir -p "$dest_dir"
  # kernel.json template in repo or feature provides placeholders; render simple kernel.json
  cat > "$dest_dir/kernel.json" <<EOF
{
  "argv": ["java", "-ea", "--enable-preview", "-jar", "$jarpath", "{connection_file}"],
  "display_name": "Java",
  "language": "java"
}
EOF
}

install_from_release() {
  # expect ARTIFACTS_BASE_URL or ARTEFACT_URL and checksums available
  local base_url=${ARTIFACTS_BASE_URL:-}
  local url=${ARTEFACT_URL:-}
  if [[ -n "$KERNEL_VERSION" ]]; then
    if [[ -z "$url" && -n "$base_url" ]]; then
      url="$base_url/java-kernel-${KERNEL_VERSION}.tar.gz"
    fi
  fi
  if [[ -z "$url" ]]; then
    echo "java-kernel: no release URL available (set ARTEFACT_URL or ARTIFACTS_BASE_URL+kernel_version)" >&2
    return 1
  fi
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT
  echo "java-kernel: downloading $url"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$tmpdir/kernel.tar.gz" "$url"
  else
    echo "curl not available" >&2; return 1
  fi
  tar -xzf "$tmpdir/kernel.tar.gz" -C "$tmpdir"
  # Expect jar under dist/ or lib/
  jar=$(find "$tmpdir" -type f -name "*ijava*.jar" -o -name "*kernel*.jar" | head -n1 || true)
  if [[ -z "$jar" ]]; then
    jar=$(find "$tmpdir" -type f -name "*.jar" | head -n1 || true)
  fi
  if [[ -z "$jar" ]]; then
    echo "java-kernel: could not find kernel jar inside release" >&2
    return 1
  fi
  dest=/usr/local/share/jupyter/kernels/java
  mkdir -p "$dest"
  cp "$jar" "$dest/ijava.jar"
  render_kernelspec "$dest" "/usr/local/share/jupyter/kernels/java/ijava.jar"
  echo "java-kernel: installed kernelspec at $dest"
}

install_from_submodule() {
  if [ ! -d "./submodules/java-kernel" ]; then
    echo "java-kernel: submodule not present at ./submodules/java-kernel" >&2
    return 1
  fi
  pushd ./submodules/java-kernel >/dev/null
  if [ -f mvnw ]; then
    ./mvnw -DskipTests package
    jar=$(find target -type f -name "*ijava*.jar" | head -n1 || true)
  elif [ -f gradlew ]; then
    ./gradlew assemble
    jar=$(find build -type f -name "*ijava*.jar" | head -n1 || true)
  else
    echo "java-kernel: no mvnw or gradlew found in submodule" >&2
    popd >/dev/null
    return 1
  fi
  popd >/dev/null
  if [[ -z "$jar" ]]; then
    echo "java-kernel: failed to build kernel jar" >&2
    return 1
  fi
  dest=/usr/local/share/jupyter/kernels/java
  mkdir -p "$dest"
  cp "$jar" "$dest/ijava.jar"
  render_kernelspec "$dest" "/usr/local/share/jupyter/kernels/java/ijava.jar"
  echo "java-kernel: installed kernelspec at $dest (built from submodule)"
}

# Main
install_jdk "$JDK_VERSION" || true
if [[ "$KERNEL_SOURCE" = "release" ]]; then
  install_from_release
else
  install_from_submodule
fi

echo "java-kernel: done"
