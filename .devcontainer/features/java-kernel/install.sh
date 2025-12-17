#!/usr/bin/env bash
set -euo pipefail

# java-kernel install.sh
# Installs a Java kernel (IJava) either by using a local artifact, downloading a release tarball
# or building from a bundled submodule. The installer prefers local artifacts and repo cache.

## Profile-variable normalization for java-kernel
# Supported variables:
# - KERNEL_SOURCE (release|source)
# - KERNEL_VERSION (explicit kernel version tag, e.g. 1.4.5)
# - JDK_VERSION (numeric major, 'latest' or 'ea')
# - ARTEFACT_URL / ARTIFACTS_BASE_URL / ARTIFACTS (artifact locations)
KERNEL_SOURCE=${KERNEL_SOURCE:-${1:-${kernel_source:-release}}}
KERNEL_VERSION=${KERNEL_VERSION:-${2:-${kernel_version:-}}}
JDK_VERSION=${JDK_VERSION:-${3:-${jdk_version:-17}}}

echo "java-kernel: KERNEL_SOURCE=${KERNEL_SOURCE} KERNEL_VERSION=${KERNEL_VERSION:-<none>} JDK_VERSION=${JDK_VERSION}"

ARTIFACTS_DIR=${ARTIFACTS_DIR:-${ARTIFACTS:-}}
if [[ -z "$ARTIFACTS_DIR" ]]; then
  if [[ -d "/tmp/Artefacts" ]]; then
    ARTIFACTS_DIR=/tmp/Artefacts
  elif [[ -d "/opt/solen/Artefacts" ]]; then
    ARTIFACTS_DIR=/opt/solen/Artefacts
  fi
fi

if [[ -z "$KERNEL_VERSION" && -n "$ARTIFACTS_DIR" ]]; then
  if [[ -f "$ARTIFACTS_DIR/versions.json" ]]; then
    ver=$(jq -r '.tools["java-kernel"] // empty' "$ARTIFACTS_DIR/versions.json" 2>/dev/null || true)
    if [[ -n "$ver" ]]; then
      KERNEL_VERSION="$ver"
      echo "java-kernel: resolved kernel version from $ARTIFACTS_DIR/versions.json -> $KERNEL_VERSION"
    fi
  fi
fi

echo "java-kernel: install (source=$KERNEL_SOURCE version=$KERNEL_VERSION jdk_version=$JDK_VERSION artifacts_dir=${ARTIFACTS_DIR:-<none>})"

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

install_jdk() {

  local ver="$1"
  echo "java-kernel: ensure JDK present (requested=${ver})"

  echo "User: $(whoami)"

  if command -v java >/dev/null 2>&1; then
    echo "java-kernel: java already available, skipping JDK install"
    return 0
  fi
  # Source SDKMAN init scripts installed by java-devtools so we can rely on the JDK it installed.
  # Export defaults for SDKMAN variables to avoid 'unbound variable' errors under set -u
  export SDKMAN_OFFLINE_MODE=${SDKMAN_OFFLINE_MODE:-false}
  export SDKMAN_CANDIDATES_API=${SDKMAN_CANDIDATES_API:-"https://api.sdkman.io/2"}
  export SDKMAN_PLATFORM=${SDKMAN_PLATFORM:-"UNIX"}
  export SDKMAN_DIR=${SDKMAN_DIR:-"$HOME/.sdkman"}

  # Temporarily disable 'set -u' while sourcing SDKMAN init snippets which may reference
  # variables not set when strict mode is enabled.
  set +u
  if [[ -f "/etc/profile.d/sdkman.sh" ]]; then
    # shellcheck disable=SC1090
    source /etc/profile.d/sdkman.sh || true
  fi
  if [[ -f "$HOME/.zshenv" ]]; then
    # shellcheck disable=SC1090
    source "$HOME/.zshenv" || true
  fi
  set -u

  if command -v java >/dev/null 2>&1; then
    echo "java-kernel: java available after sourcing SDKMAN init"
    return 0
  fi

  echo "java-kernel: JDK not available. This feature assumes 'java-devtools' ran earlier and installed a JDK via SDKMAN. Please ensure profile order runs java-devtools before java-kernel." >&2
  return 1
}

install_from_release() {
  local base_url=${ARTIFACTS_BASE_URL:-}
  local url=${ARTEFACT_URL:-}

  local artifacts_dir=${ARTIFACTS_DIR:-${ARTIFACTS:-}}
  if [[ -n "$artifacts_dir" ]]; then
    if [[ -n "$KERNEL_VERSION" ]]; then
      candidate="$artifacts_dir/java-kernel-${KERNEL_VERSION}.tar.gz"
      if [[ ! -f "$candidate" ]]; then
        candidate="$artifacts_dir/IJava-${KERNEL_VERSION}.zip"
      fi
      if [[ ! -f "$candidate" ]]; then
        candidate=$(ls "$artifacts_dir"/java-kernel-*.tar.gz 2>/dev/null || true)
        candidate=$(printf '%s' "$candidate" | head -n1)
      fi
    else
      candidate=$(ls "$artifacts_dir"/java-kernel-*.tar.gz "$artifacts_dir"/IJava-*.zip 2>/dev/null || true)
      candidate=$(printf '%s' "$candidate" | head -n1)
    fi
    if [ -n "$candidate" ] && [ -f "$candidate" ]; then
      echo "java-kernel: found local artifact at $candidate, using it"
      tmpdir=$(mktemp -d)
      trap 'rm -rf "$tmpdir"' EXIT
      cp "$candidate" "$tmpdir/kernel.tar.gz"
      if [[ "$candidate" == *.zip ]]; then
        unzip -q "$tmpdir/kernel.tar.gz" -d "$tmpdir" || true
      else
        tar -xzf "$tmpdir/kernel.tar.gz" -C "$tmpdir" || true
      fi
      jar=$(find "$tmpdir" -type f -name "*ijava*.jar" -o -name "*kernel*.jar" | head -n1 || true)
      if [[ -z "$jar" ]]; then
        jar=$(find "$tmpdir" -type f -name "*.jar" | head -n1 || true)
      fi
      if [[ -z "$jar" ]]; then
        echo "java-kernel: could not find kernel jar inside local artifact" >&2
        return 1
      fi
      dest=/usr/local/share/jupyter/kernels/java
      mkdir -p "$dest"
      cp "$jar" "$dest/ijava.jar"
      render_kernelspec "$dest" "/usr/local/share/jupyter/kernels/java/ijava.jar"
      echo "java-kernel: installed kernelspec at $dest"
      return 0
    fi

    repo_cache="$artifacts_dir/features/java-kernel/toolcache/java-kernel/${KERNEL_VERSION}"
    if [[ -n "$KERNEL_VERSION" && -d "$repo_cache" ]]; then
      found=$(ls "$repo_cache"/java-kernel-*.tar.gz 2>/dev/null || true)
      found=$(printf '%s' "$found" | head -n1)
      if [[ -n "$found" && -f "$found" ]]; then
        echo "java-kernel: found repo-cached artifact at $found, using it"
        tmpdir=$(mktemp -d)
        trap 'rm -rf "$tmpdir"' EXIT
        cp "$found" "$tmpdir/kernel.tar.gz"
        if [[ "$found" == *.zip ]]; then
          unzip -q "$tmpdir/kernel.tar.gz" -d "$tmpdir" || true
        else
          tar -xzf "$tmpdir/kernel.tar.gz" -C "$tmpdir" || true
        fi
        jar=$(find "$tmpdir" -type f -name "*ijava*.jar" -o -name "*kernel*.jar" | head -n1 || true)
        if [[ -z "$jar" ]]; then
          jar=$(find "$tmpdir" -type f -name "*.jar" | head -n1 || true)
        fi
        if [[ -z "$jar" ]]; then
          echo "java-kernel: could not find kernel jar inside repo-cached artifact" >&2
          return 1
        fi
        dest=/usr/local/share/jupyter/kernels/java
        mkdir -p "$dest"
        cp "$jar" "$dest/ijava.jar"
        render_kernelspec "$dest" "/usr/local/share/jupyter/kernels/java/ijava.jar"
        echo "java-kernel: installed kernelspec at $dest (from repo cache)"
        return 0
      fi
    fi
  fi

  if [[ -n "$KERNEL_VERSION" ]]; then
    if [[ -z "$url" && -n "$base_url" ]]; then
      url="$base_url/java-kernel-${KERNEL_VERSION}.tar.gz"
    fi
  fi
  # If no URL and no local artifact found, try GitHub releases for IJava (both v<ver> and <ver> tags)
  if [[ -z "$url" ]]; then
    set +u
    echo "java-kernel: attempting to locate release on GitHub for version='${KERNEL_VERSION:-<latest>}'"
    # Helper to probe a URL exists (HEAD) and return it if accessible
    probe_url() {
      local u="$1"
      if command -v curl >/dev/null 2>&1; then
        if curl -fsSLI "$u" >/dev/null 2>&1; then
          printf '%s' "$u"
          return 0
        fi
      fi
      return 1
    }

    if [[ -n "$KERNEL_VERSION" ]]; then
      # Try common GitHub release asset locations for ebpro/IJava
      try_urls=(
        "https://github.com/ebpro/IJava/releases/download/v${KERNEL_VERSION}/IJava-${KERNEL_VERSION}.zip"
        "https://github.com/ebpro/IJava/releases/download/${KERNEL_VERSION}/IJava-${KERNEL_VERSION}.zip"
        "https://github.com/ebpro/IJava/releases/download/v${KERNEL_VERSION}/IJava-latest.zip"
        "https://github.com/ebpro/IJava/releases/download/${KERNEL_VERSION}/IJava-latest.zip"
        "https://github.com/ebpro/IJava/releases/download/v${KERNEL_VERSION}/java-kernel-${KERNEL_VERSION}.tar.gz"
        "https://github.com/ebpro/IJava/releases/download/${KERNEL_VERSION}/java-kernel-${KERNEL_VERSION}.tar.gz"
      )
      # Create a temporary dir for direct download attempts
      tmp_probe_dir=$(mktemp -d)
      trap 'rm -rf "$tmp_probe_dir"' EXIT
      for u in "${try_urls[@]}"; do
        echo "java-kernel: attempting download from $u"
        if command -v curl >/dev/null 2>&1; then
          if curl -fsSL -o "$tmp_probe_dir/kernel.tar.gz" "$u"; then
            # Download succeeded; use this file
            echo "java-kernel: downloaded release from $u"
            url="$tmp_probe_dir/kernel.tar.gz"
            downloaded_from_github=true
            break
          else
            echo "java-kernel: download failed for $u"
          fi
        else
          echo "java-kernel: curl not available to probe $u"
        fi
      done
    else
      # No version requested: ask GitHub API for latest release and pick first matching asset
      if command -v curl >/dev/null 2>&1; then
        api_url="https://api.github.com/repos/ebpro/IJava/releases/latest"
        body=$(curl -fsSL "$api_url" 2>/dev/null || true)
        if [[ -n "$body" ]]; then
          # Try to find browser_download_url for IJava-*.zip or java-kernel-*.tar.gz
          url=$(printf '%s' "$body" | grep -E '"browser_download_url":' | sed -E 's/.*"browser_download_url": "([^"]+)".*/\1/' | grep -E 'IJava-.*\.zip|java-kernel-.*\.tar\.gz' | head -n1 || true)
          if [[ -n "$url" ]]; then
            echo "java-kernel: found GitHub latest release asset: $url"
          else
            echo "java-kernel: GitHub latest release JSON fetched but no suitable asset found"
          fi
        else
          echo "java-kernel: GitHub API returned empty body for latest release"
        fi
      fi
    fi
    set -u
  fi
  # If still no URL, but we have a kernel version, construct the common release asset URL directly
  if [[ -z "$url" && -n "$KERNEL_VERSION" ]]; then
    url="https://github.com/ebpro/IJava/releases/download/v${KERNEL_VERSION}/IJava-latest.zip"
    echo "java-kernel: fallback using constructed GitHub URL: $url"
  fi
  if [[ -z "$url" ]]; then
    echo "java-kernel: no release URL available (set ARTEFACT_URL or ARTIFACTS_BASE_URL+kernel_version)" >&2
    return 1
  fi
  # Prepare download target and preserve extension when possible
  download_file=""
  if [[ -n "${downloaded_from_github:-}" && "$downloaded_from_github" = true && -f "$url" ]]; then
    # url is a local downloaded file
    download_file="$url"
    tmpdir_parent=$(dirname "$download_file")
    extract_dir="$tmpdir_parent"
  else
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT
    echo "java-kernel: downloading $url"
    # try to guess extension from URL
    if [[ "$url" =~ \.zip($|\?) ]]; then
      out="$tmpdir/kernel.zip"
    else
      out="$tmpdir/kernel.tar.gz"
    fi
    if command -v curl >/dev/null 2>&1; then
      if ! curl -fsSL -o "$out" "$url"; then
        echo "java-kernel: download failed for $url" >&2
        return 1
      fi
    else
      echo "curl not available" >&2; return 1
    fi
    download_file="$out"
    extract_dir="$tmpdir"
  fi

  # Extract the archive. Prefer unzip for .zip files, otherwise try tar.
  if printf '%s' "$download_file" | grep -E '\.zip$' >/dev/null 2>&1; then
    if command -v unzip >/dev/null 2>&1; then
      unzip -q "$download_file" -d "$extract_dir" || { echo "java-kernel: unzip failed, attempting tar fallback" >&2; true; }
    else
      # attempt jar x -f as a fallback for zip if unzip not available
      (cd "$extract_dir" && jar xf "$download_file") || true
    fi
  else
    # try tar first; on failure, try unzip as last resort
    if tar -xzf "$download_file" -C "$extract_dir" 2>/dev/null; then
      :
    else
      if command -v unzip >/dev/null 2>&1; then
        unzip -q "$download_file" -d "$extract_dir" || true
      else
        (cd "$extract_dir" && jar xf "$download_file") || true
      fi
    fi
  fi
  jar=$(find "$extract_dir" -type f -name "*ijava*.jar" -o -name "*kernel*.jar" | head -n1 || true)
  if [[ -z "$jar" ]]; then
    jar=$(find "$extract_dir" -type f -name "*.jar" | head -n1 || true)
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


# Main: always install from release. Ensure a JDK is available in the image (any version).
install_jdk "$JDK_VERSION" || { echo "java-kernel: JDK required for the environment; ensure 'java-devtools' feature or base image provides a JDK/SDKMAN init before this feature." >&2; exit 1; }

install_from_release || { echo "java-kernel: failed to install from release" >&2; exit 1; }

echo "java-kernel: done"
