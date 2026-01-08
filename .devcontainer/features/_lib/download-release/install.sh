#!/usr/bin/env bash
set -euo pipefail

# Shared Binary Release Downloader
# Provides reusable functions for downloading binaries from GitHub releases or direct URLs
# This installs helper functions to /usr/local/lib/download-release-helpers.sh

echo "===================================================================="
echo "Feature: Binary Release Downloader Helper (_lib/download-release)"
echo "===================================================================="

HELPER_LIB="/usr/local/lib/download-release-helpers.sh"

mkdir -p "$(dirname "$HELPER_LIB")"

cat > "$HELPER_LIB" << 'HELPER_EOF'
#!/usr/bin/env bash
# Binary Release Download Helpers
# Source this file to use download_github_release and download_direct functions

# Architecture mapping for common platforms
_map_architecture() {
    local arch="${1:-$(uname -m)}"
    case "$arch" in
        x86_64|X86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7*|armhf) echo "armv7" ;;
        *) echo "$arch" ;;
    esac
}

# Download and install a binary from GitHub releases
# Usage: download_github_release REPO TOOL VERSION [INSTALL_DIR] [FILENAME_PATTERN] [EXTRACT]
#
# Arguments:
#   REPO: GitHub repository (e.g., "cli/cli", "tilt-dev/tilt")
#   TOOL: Binary name to install (e.g., "gh", "tilt")
#   VERSION: Version to install (e.g., "2.40.0") or "latest"
#   INSTALL_DIR: Target directory (default: /usr/local/bin)
#   FILENAME_PATTERN: Release filename pattern, ARCH/VERSION replaced (default: "{tool}_{version}_linux_{arch}.tar.gz")
#   EXTRACT: true to extract tar.gz, false to use binary directly (default: true)
#
# Examples:
#   download_github_release "cli/cli" "gh" "2.40.0"
#   download_github_release "tilt-dev/tilt" "tilt" "latest" "/usr/local/bin" "tilt.{version}.linux.{arch}.tar.gz"
#   download_github_release "junegunn/fzf" "fzf" "0.45.0" "/usr/local/bin" "fzf-{version}-linux_{arch}.tar.gz"
download_github_release() {
    local repo="$1"
    local tool="$2"
    local version="$3"
    local install_dir="${4:-/usr/local/bin}"
    local filename_pattern="${5:-{tool}_{version}_linux_{arch}.tar.gz}"
    local extract="${6:-true}"

    echo "📦 Downloading $tool from GitHub ($repo)..."

    # Detect architecture
    local arch
    arch=$(_map_architecture)
    echo "   Architecture: $arch"

    # Resolve latest version if needed
    if [ "$version" = "latest" ]; then
        echo "   Resolving latest version..."
        if command -v curl >/dev/null 2>&1; then
            version=$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" | \
                grep -oP '"tag_name": "\K(.*)(?=")' | sed 's/^v//' || echo "")
        fi
        if [ -z "$version" ]; then
            echo "❌ Failed to resolve latest version for $repo"
            return 1
        fi
        echo "   Latest version: $version"
    fi

    # Build filename from pattern
    local filename="$filename_pattern"
    filename="${filename//\{tool\}/$tool}"
    filename="${filename//\{version\}/$version}"
    filename="${filename//\{arch\}/$arch}"

    # Support malformed templates like "{tool_{version}_linux_{arch}.tar.gz}" where
    # only {version} and {arch} were replaced leaving a single-braced token.
    # Convert "{tool_2.0_linux_arm64.tar.gz}" -> "${tool}_2.0_linux_arm64.tar.gz"
    if [[ "$filename" =~ \{tool_(.*)\} ]]; then
        inner="${BASH_REMATCH[1]}"
        filename="${tool}_${inner}"
    fi

    # Strip any surrounding braces left accidentally
    filename="${filename#\{}"
    filename="${filename%\}}"

    # Build download URL
    local url="https://github.com/$repo/releases/download/v${version}/$filename"
    echo "   URL: $url"

    # Download with retries
    local tmpfile="/tmp/${tool}-${version}.download"
    local max_attempts=3
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        echo "   Download attempt $attempt/$max_attempts..."
        if curl -fsSL -o "$tmpfile" "$url"; then
            echo "   ✅ Download successful"
            break
        fi
        echo "   ⚠️  Download failed, retrying..."
        attempt=$((attempt + 1))
        sleep 2
    done

    if [ ! -f "$tmpfile" ]; then
        echo "❌ Failed to download $tool after $max_attempts attempts"
        return 1
    fi

    # Extract or copy binary
    mkdir -p "$install_dir"

    if [ "$extract" = "true" ]; then
        echo "   Extracting archive..."
        local extract_dir="/tmp/${tool}-extract"
        mkdir -p "$extract_dir"

        if tar -xzf "$tmpfile" -C "$extract_dir" 2>/dev/null; then
            # Find the binary (might be in subdirectory)
            local binary_path
            binary_path=$(find "$extract_dir" -type f -name "$tool" -executable | head -1)

            if [ -z "$binary_path" ]; then
                # Try common patterns
                if [ -f "$extract_dir/$tool" ]; then
                    binary_path="$extract_dir/$tool"
                elif [ -f "$extract_dir/bin/$tool" ]; then
                    binary_path="$extract_dir/bin/$tool"
                fi
            fi

            if [ -n "$binary_path" ] && [ -f "$binary_path" ]; then
                cp "$binary_path" "$install_dir/$tool"
                chmod +x "$install_dir/$tool"
                echo "   ✅ Installed to $install_dir/$tool"
            else
                echo "❌ Binary $tool not found in archive"
                rm -rf "$extract_dir" "$tmpfile"
                return 1
            fi

            rm -rf "$extract_dir"
        else
            echo "❌ Failed to extract archive"
            rm -f "$tmpfile"
            return 1
        fi
    else
        # Direct binary, no extraction
        cp "$tmpfile" "$install_dir/$tool"
        chmod +x "$install_dir/$tool"
        echo "   ✅ Installed to $install_dir/$tool"
    fi

    rm -f "$tmpfile"

    # Verify installation
    if [ -x "$install_dir/$tool" ]; then
        echo "   🎉 $tool installed successfully"
        if "$install_dir/$tool" --version >/dev/null 2>&1 || \
           "$install_dir/$tool" version >/dev/null 2>&1; then
            "$install_dir/$tool" --version 2>/dev/null || "$install_dir/$tool" version 2>/dev/null || true
        fi
        return 0
    else
        echo "❌ Installation verification failed"
        return 1
    fi
}

# Download and install a binary from a direct URL
# Usage: download_direct URL TOOL [INSTALL_DIR] [EXTRACT]
#
# Arguments:
#   URL: Direct download URL
#   TOOL: Binary name to install
#   INSTALL_DIR: Target directory (default: /usr/local/bin)
#   EXTRACT: true to extract tar.gz, false to use binary directly (default: true)
#
# Examples:
#   download_direct "https://example.com/tool.tar.gz" "tool"
#   download_direct "https://example.com/binary" "tool" "/usr/local/bin" "false"
download_direct() {
    local url="$1"
    local tool="$2"
    local install_dir="${3:-/usr/local/bin}"
    local extract="${4:-true}"

    echo "📦 Downloading $tool from direct URL..."
    echo "   URL: $url"

    # Download with retries
    local tmpfile="/tmp/${tool}.download"
    local max_attempts=3
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        echo "   Download attempt $attempt/$max_attempts..."
        if curl -fsSL -o "$tmpfile" "$url"; then
            echo "   ✅ Download successful"
            break
        fi
        echo "   ⚠️  Download failed, retrying..."
        attempt=$((attempt + 1))
        sleep 2
    done

    if [ ! -f "$tmpfile" ]; then
        echo "❌ Failed to download $tool after $max_attempts attempts"
        return 1
    fi

    # Extract or copy binary (same logic as download_github_release)
    mkdir -p "$install_dir"

    if [ "$extract" = "true" ]; then
        echo "   Extracting archive..."
        local extract_dir="/tmp/${tool}-extract"
        mkdir -p "$extract_dir"

        if tar -xzf "$tmpfile" -C "$extract_dir" 2>/dev/null; then
            local binary_path
            binary_path=$(find "$extract_dir" -type f -name "$tool" -executable | head -1)

            if [ -z "$binary_path" ]; then
                if [ -f "$extract_dir/$tool" ]; then
                    binary_path="$extract_dir/$tool"
                elif [ -f "$extract_dir/bin/$tool" ]; then
                    binary_path="$extract_dir/bin/$tool"
                fi
            fi

            if [ -n "$binary_path" ] && [ -f "$binary_path" ]; then
                cp "$binary_path" "$install_dir/$tool"
                chmod +x "$install_dir/$tool"
                echo "   ✅ Installed to $install_dir/$tool"
            else
                echo "❌ Binary $tool not found in archive"
                rm -rf "$extract_dir" "$tmpfile"
                return 1
            fi

            rm -rf "$extract_dir"
        else
            echo "❌ Failed to extract archive"
            rm -f "$tmpfile"
            return 1
        fi
    else
        cp "$tmpfile" "$install_dir/$tool"
        chmod +x "$install_dir/$tool"
        echo "   ✅ Installed to $install_dir/$tool"
    fi

    rm -f "$tmpfile"

    # Verify
    if [ -x "$install_dir/$tool" ]; then
        echo "   🎉 $tool installed successfully"
        return 0
    else
        echo "❌ Installation verification failed"
        return 1
    fi
}

# Export functions
export -f _map_architecture download_github_release download_direct
HELPER_EOF

chmod +x "$HELPER_LIB"

echo "✅ Binary release downloader helper installed to $HELPER_LIB"
echo ""
echo "Usage in feature install.sh:"
echo "  source /usr/local/lib/download-release-helpers.sh"
echo "  download_github_release \"cli/cli\" \"gh\" \"2.40.0\""
echo "  download_direct \"https://example.com/tool.tar.gz\" \"tool\""
echo "===================================================================="
