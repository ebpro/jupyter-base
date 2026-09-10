# Auto-inserted by scripts/inject_prebaked_helpers.sh
# Source shared feature helpers (prebaked into image) or fall back to repository helper
if [ -n "${FEATURE_HELPERS_DIR:-}" ] && [ -f "${FEATURE_HELPERS_DIR}/helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "${FEATURE_HELPERS_DIR}/helpers.sh"
elif [ -f "../../../scripts/feature_helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "../../../scripts/feature_helpers.sh"
fi
#!/usr/bin/env bash
set -euo pipefail

# java-kernel install.sh
# Installs a Java kernel (IJava) by downloading a release tarball OR using prebaked artifacts.
# Relies on ARTIFACTS_BASE_URL or ARTEFACT_URL to point to a release tarball.

KERNEL_VERSION=${KERNEL_VERSION:-${1:-${kernel_version:-v1.4.6-pr12}}}
JDK_VERSION=${JDK_VERSION:-${2:-${jdk_version:-25}}}
CONDA_DIR=${CONDA_DIR:-/home/${NB_USER:-jovyan}/miniforge3}

echo "java-kernel: version=${KERNEL_VERSION} jdk=${JDK_VERSION} conda=${CONDA_DIR}"

## JDK installation handled by `java-jdk` feature during image build.

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

install_from_prebaked() {
  # Check for prebaked artifacts in /tmp/artefacts/java-kernel/toolcache
  local ver="${KERNEL_VERSION#v}"  # remove leading 'v'
  local prebaked_dir="/tmp/artefacts/java-kernel/toolcache/java-kernel/${ver}/extracted/java"

  if [[ -d "$prebaked_dir" ]]; then
    echo "java-kernel: found prebaked artifacts at $prebaked_dir"

    local jar=$(find "$prebaked_dir" -type f \( -iname '*ijava*.jar' -o -iname '*kernel*.jar' \) | head -n1 || true)
    if [[ -z "$jar" ]]; then
      echo "java-kernel: no jar found in prebaked artifacts" >&2
      return 1
    fi

    CONDA_DIR=${CONDA_DIR:-/home/${NB_USER:-jovyan}/miniforge3}
    dest="${CONDA_DIR}/share/jupyter/kernels/java"
    mkdir -p "$dest"
    cp "$jar" "$dest/ijava.jar"
    render_kernelspec "$dest" "${dest}/ijava.jar"
    # ensure ownership for the notebook user
    chown -R ${NB_UID:-1001}:${NB_GID:-1001} "$dest" >/dev/null 2>&1 || true
    echo "java-kernel: installed kernelspec from prebaked artifacts at $dest"
    return 0
  fi

  return 1
}

install_from_release() {
  # expect ARTIFACTS_BASE_URL or ARTEFACT_URL and checksums available
  local base_url=${ARTIFACTS_BASE_URL:-}
  local url=${ARTEFACT_URL:-}
  local candidate_url
  local version_tag="${KERNEL_VERSION}"
  local version_raw="${KERNEL_VERSION#v}"

  # If user provided base url and version, try to construct common release URL patterns
  if [[ -z "$url" && -n "$KERNEL_VERSION" && -n "$base_url" ]]; then
    if echo "$base_url" | grep -qi "github.com"; then
      for candidate_url in \
        "${base_url%/}/download/${version_tag}/IJava-latest.zip" \
        "${base_url%/}/download/${version_tag}/IJava-${version_tag}.zip" \
        "${base_url%/}/download/${version_tag}/IJava-${version_raw}.zip"
      do
        if curl -fsIL --max-time 20 "$candidate_url" >/dev/null 2>&1; then
          url="$candidate_url"
          break
        fi
      done
    else
      url="${base_url%/}/java-kernel-${KERNEL_VERSION}.tar.gz"
    fi
  fi

  if [[ -z "$url" ]]; then
    echo "java-kernel: no release URL available (set ARTEFACT_URL or ARTIFACTS_BASE_URL+KERNEL_VERSION)" >&2
    return 1
  fi

  tmpdir=$(mktemp -d)
  chmod 755 "$tmpdir"
  trap 'rm -rf "$tmpdir"' EXIT
  echo "java-kernel: downloading $url"

  # Download artefact
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$tmpdir/kernel.archive" "$url" || { echo "java-kernel: download failed" >&2; return 1; }
  else
    echo "curl not available" >&2; return 1
  fi

  # Try to fetch checksum alongside (url + .sha256)
  if command -v curl >/dev/null 2>&1; then
    if curl -fsSL -o "$tmpdir/kernel.sha256" "${url}.sha256" 2>/dev/null; then
      expected=$(awk '{print $1}' "$tmpdir/kernel.sha256" | tr -d '\r\n' || true)
      if [ -n "$expected" ]; then
        if command -v sha256sum >/dev/null 2>&1; then
          actual=$(sha256sum "$tmpdir/kernel.archive" | awk '{print $1}') || true
        elif command -v shasum >/dev/null 2>&1; then
          actual=$(shasum -a 256 "$tmpdir/kernel.archive" | awk '{print $1}') || true
        elif command -v openssl >/dev/null 2>&1; then
          actual=$(openssl dgst -sha256 "$tmpdir/kernel.archive" | awk '{print $2}') || true
        else
          echo "java-kernel: no checksum tool available to verify artifact" >&2
          rm -f "$tmpdir/kernel.sha256"
          actual=""
        fi
        if [ -n "$actual" ] && [ "$expected" != "$actual" ]; then
          echo "java-kernel: checksum mismatch (expected $expected, got $actual)" >&2
          return 1
        fi
      fi
    fi
  fi

  # Extract depending on archive type
  case "$tmpdir/kernel.archive" in
    *.zip)
      if command -v unzip >/dev/null 2>&1; then
        unzip -q "$tmpdir/kernel.archive" -d "$tmpdir"
      else
        echo "java-kernel: unzip not available to extract zip archive" >&2; return 1
      fi
      ;;
    *.tar.gz|*.tgz)
      tar -xzf "$tmpdir/kernel.archive" -C "$tmpdir"
      ;;
    *)
      # try tar first, then try unzip by treating as zip
      if tar -tzf "$tmpdir/kernel.archive" >/dev/null 2>&1; then
        tar -xzf "$tmpdir/kernel.archive" -C "$tmpdir"
      elif command -v unzip >/dev/null 2>&1; then
        unzip -q "$tmpdir/kernel.archive" -d "$tmpdir"
      else
        echo "java-kernel: unknown archive format and no extractor available" >&2; return 1
      fi
      ;;
  esac

  chmod -R a+rX "$tmpdir" 2>/dev/null || true

  # Prefer the release-provided installer when present (IJava >= 1.4.6-pr*)
  install_py=$(find "$tmpdir" -type f -name install.py | head -n1 || true)
  if [[ -n "$install_py" ]]; then
    python_bin="${CONDA_DIR}/bin/python"
    if [[ ! -x "$python_bin" ]]; then
      python_bin=$(command -v python3 || true)
    fi
    if [[ -z "$python_bin" ]]; then
      echo "java-kernel: no Python interpreter available to run install.py" >&2
      return 1
    fi

    install_script_dir=$(dirname "$install_py")
    if [[ "$(id -u)" == "0" ]]; then
      su - "${NB_USER:-jovyan}" -c "cd '$install_script_dir' && '$python_bin' '$install_py' --sys-prefix --replace"
    else
      (cd "$install_script_dir" && "$python_bin" "$install_py" --sys-prefix --replace)
    fi
    chown -R ${NB_UID:-1001}:${NB_GID:-1001} "${CONDA_DIR}/share/jupyter/kernels/java" >/dev/null 2>&1 || true
    echo "java-kernel: installed kernelspec via install.py"
    return 0
  fi

  # Expect jar under dist/ or lib/ or root
  jar=$(find "$tmpdir" -type f \( -iname '*ijava*.jar' -o -iname '*kernel*.jar' \) | head -n1 || true)
  if [[ -z "$jar" ]]; then
    jar=$(find "$tmpdir" -type f -iname '*.jar' | head -n1 || true)
  fi
  if [[ -z "$jar" ]]; then
    echo "java-kernel: could not find kernel jar inside release" >&2
    return 1
  fi

  dest="${CONDA_DIR}/share/jupyter/kernels/java"
  mkdir -p "$dest"
  cp "$jar" "$dest/ijava.jar"
  render_kernelspec "$dest" "${dest}/ijava.jar"
  # ensure ownership for the notebook user
  chown -R ${NB_UID:-1001}:${NB_GID:-1001} "$dest" >/dev/null 2>&1 || true
  echo "java-kernel: installed kernelspec at $dest"
}


# Try prebaked artifacts first, then fall back to release download
if install_from_prebaked; then
  echo "java-kernel: successfully installed from prebaked artifacts"
elif install_from_release; then
  echo "java-kernel: successfully installed from release download"
else
  echo "java-kernel: installation failed - no prebaked artifacts or release download available" >&2
  exit 1
fi

echo "java-kernel: done"
