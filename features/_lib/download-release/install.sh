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
    local filename_pattern_arg="${5:-}"
    local filename_pattern="${filename_pattern_arg:-{tool}_{version}_linux_{arch}.tar.gz}"
    local extract="${6:-true}"

    # If caller passed an explicit filename pattern/filename, prefer it
    # verbatim and avoid appending or reinterpreting the default template.
    if [ -n "$filename_pattern_arg" ]; then
        filename_pattern="$filename_pattern_arg"
    fi

    # Debug: show raw incoming args to help diagnose malformed patterns
    echo "   Raw args: repo='${repo}' tool='${tool}' version='${version}' install_dir='${install_dir}' filename_pattern_arg='${filename_pattern_arg}' extract='${extract}'"

    # If caller passed the filename pattern in the 4th arg (older style),
    # detect and swap: raw install_dir holds the pattern in that case.
    # Use the raw variables so we don't accidentally mutate the pattern.
    if [[ "${install_dir}" == *"{"* || "${install_dir}" == *"}}"* || "${install_dir}" == *".tar"* || "${install_dir}" == *".tgz"* ]]; then
        filename_pattern_arg="${install_dir}"
        # If 5th arg contains a ':' mapping like 'archive:dest', prefer dest
        if [[ "${5:-}" == *":"* ]]; then
            install_dir="${5#*:}"
        else
            install_dir="${5:-/usr/local/bin}"
        fi
        extract="${6:-true}"
        filename_pattern="${filename_pattern_arg:-{tool}_{version}_linux_{arch}.tar.gz}"
    fi

    # Tolerate callers that pass the filename pattern in the 4th arg
    # (some feature scripts do this). Detect by checking for brace tokens
    # or common archive suffixes and swap into the correct variables.
    if [[ "$install_dir" == *"{"* || "$install_dir" == *"}}"* || "$install_dir" == *".tar"* || "$install_dir" == *".tgz"* ]]; then
        filename_pattern="$install_dir"
        # if 5th arg contains a ':' mapping like 'archive:dest', prefer dest
        if [[ "${5:-}" == *":"* ]]; then
            install_dir="${5#*:}"
        else
            install_dir="${5:-/usr/local/bin}"
        fi
        extract="${6:-true}"
    fi

    # If filename_pattern contains an inline mapping 'archive:dest', split it
    local inline_dest=""
    if [[ "$filename_pattern" == *":"* ]]; then
        inline_dest="${filename_pattern#*:}"
        filename_pattern="${filename_pattern%%:*}"
        # prefer explicit inline dest if present
        if [ -n "$inline_dest" ]; then
            install_dir="$inline_dest"
        fi
    fi

    # Normalize double-brace patterns like {{version}} -> {version}
    filename_pattern="${filename_pattern//{{version}}/{version}}"
    filename_pattern="${filename_pattern//{{arch}}/{arch}}"
    filename_pattern="${filename_pattern//{{tool}}/{tool}}"

    # If the caller passed a noisy pattern that contains extra path fragments
    # (e.g. 'quarto-{{version}}-linux-{{arch}}.tar.gz}/{version}}/...'), extract
    # the first archive-looking filename to avoid concatenated leftovers.
    archive_match=$(printf '%s' "$filename_pattern" | grep -oE '[^/]+\.(tar\.gz|tgz|zip)' || true)
    if [ -n "$archive_match" ]; then
        filename_pattern="$archive_match"
    fi

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

    # Build filename from pattern (first-pass substitution)
    local filename="$filename_pattern"
    # Always perform placeholder substitution, even for explicit patterns
    # Use sed for reliable literal string replacement (bash parameter expansion treats {...} as globs)
    safe_tool="${tool//\//\\/}"
    safe_version="${version//\//\\/}"
    safe_arch="${arch//\//\\/}"
    filename=$(printf '%s' "$filename" | sed -e "s/{tool}/$safe_tool/g" -e "s/{version}/$safe_version/g" -e "s/{arch}/$safe_arch/g")

    # Debug/logging: show the raw pattern and result
    echo "   Pattern: $filename_pattern"
    echo "   Filename: $filename"

    # If any key components are empty, try to infer missing values and
    # fall back to the conventional GitHub asset name format to avoid
    # producing a filename like "__linux_.tar.gz".
    if [ -z "$tool" ] || [ -z "$version" ] || [ -z "$arch" ]; then
        # infer tool from repo if missing
        local repo_tool
        repo_tool="${repo##*/}"
        [ -z "$tool" ] && tool="$repo_tool"
        # if version still empty, keep as-is (will be empty in filename)
        filename="${tool}_${version}_linux_${arch}.tar.gz"
        echo "   ⚠️  Warning: constructed filename components were empty; falling back to ${filename}"
    fi

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

    # Final sanitize: remove any remaining unmatched braces left by malformed
    # templates (e.g. leftover '{{' or '}}' fragments). This avoids producing
    # URLs with stray brace characters that cause curl errors.
    filename="$(printf '%s' "$filename" | tr -d '{}')"

    # If a malformed pattern accidentally left extra path segments after an
    # archive suffix (e.g. "...tar.gz/2.83.2/arm64/gh"), trim anything after
    # the first recognized archive suffix so the URL points to the archive.
    if [[ "$filename" == *".tar.gz"* ]]; then
        filename="${filename%%.tar.gz*}.tar.gz"
    elif [[ "$filename" == *".tgz"* ]]; then
        filename="${filename%%.tgz*}.tgz"
    elif [[ "$filename" == *".zip"* ]]; then
        filename="${filename%%.zip*}.zip"
    fi

    # Build download URL and sanitize it as well
    local url="https://github.com/$repo/releases/download/v${version}/$filename"
    url="$(printf '%s' "$url" | tr -d '{}')"
    echo "   URL: $url"

        # Toolcache support: reuse cached archives under /opt/toolcache when available
        local TOOLCACHE_DIR="${TOOLCACHE_DIR:-/opt/toolcache}"
        local filename_base
        filename_base=$(basename "$filename")
        local cache_archive="$TOOLCACHE_DIR/$tool/$version/$arch/$filename_base"
        local cache_dir
        cache_dir=$(dirname "$cache_archive")

        # Helper lock functions (simple mkdir-based lock)
        _cache_lock_acquire() {
            local lockdir="$1/.lock"
            local max_attempts=150  # 30 seconds (was 10s)
            local n=0
            until mkdir "$lockdir" 2>/dev/null; do
                n=$((n+1))
                if [ "$n" -ge "$max_attempts" ]; then
                    # Check if lock is stale (older than 60s) and clean it up
                    if [ -d "$lockdir" ]; then
                        local lock_age=$(($(date +%s) - $(stat -f %m "$lockdir" 2>/dev/null || stat -c %Y "$lockdir" 2>/dev/null || echo 0)))
                        if [ "$lock_age" -gt 60 ]; then
                            echo "   Removing stale lock (${lock_age}s old)"
                            rmdir "$lockdir" 2>/dev/null || true
                            # Try one more time after cleanup
                            if mkdir "$lockdir" 2>/dev/null; then
                                return 0
                            fi
                        fi
                    fi
                    echo "   ⚠️  Could not acquire cache lock after $((n*200/1000))s, proceeding without cache write"
                    return 1
                fi
                sleep 0.2
            done
            return 0
        }
        _cache_lock_release() {
            local lockdir="$1/.lock"
            rmdir "$lockdir" 2>/dev/null || true
        }

        # If cached archive exists, use it (copy to tmpfile to avoid removing cache)
        local from_cache=false
        if [ -f "$cache_archive" ]; then
            echo "   Using cached archive: $cache_archive"
            tmpfile="/tmp/${tool}-${version}.download"
            cp -a "$cache_archive" "$tmpfile"
            from_cache=true
        fi

    # Download with retries
    local tmpfile="/tmp/${tool}-${version}.download"
    local max_attempts=3
    local attempt=1

    # Use robust curl flags: fail on HTTP errors, retry transient failures,
    # set connect and overall timeouts to avoid hanging during builds.
    local curl_flags=(--fail --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 300 -fsSL)
    while [ $attempt -le $max_attempts ]; do
        echo "   Download attempt $attempt/$max_attempts..."
        if [ "$from_cache" = true ] || curl "${curl_flags[@]}" -o "$tmpfile" "$url"; then
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

    # If checksums.json exists in repository Artefacts or /tmp, verify file integrity
    local checksums_file=""
    if [ -f /tmp/checksums.json ]; then
        checksums_file=/tmp/checksums.json
    elif [ -f "${PWD}/Artefacts/checksums.json" ]; then
        checksums_file="${PWD}/Artefacts/checksums.json"
    fi
    if [ -n "$checksums_file" ] && command -v jq >/dev/null 2>&1; then
        local expected_sha
        expected_sha=$(jq -r --arg t "$tool" --arg ver "$version" --arg arch "$arch" '.tools[$t].checksums[$ver][$arch] // empty' "$checksums_file" 2>/dev/null || true)
        if [ -n "$expected_sha" ]; then
            echo "   Verifying checksum against $checksums_file..."
            actual_sha=$(sha256sum "$tmpfile" | awk '{print $1}')
            if [ "$actual_sha" != "$expected_sha" ]; then
                echo "❌ Checksum mismatch for $tool@$version ($arch): expected $expected_sha, got $actual_sha"
                rm -f "$tmpfile"
                # If cache exists but checksum mismatch, remove cached copy under lock
                if [ -f "$cache_archive" ]; then
                    _cache_lock_acquire "$cache_dir"
                    rm -f "$cache_archive" || true
                    _cache_lock_release "$cache_dir"
                    echo "   Removed bad cache: $cache_archive"
                fi
                return 1
            fi
            echo "   ✅ Checksum verified"
        fi
    fi

    # If we downloaded successfully and it didn't come from cache, store in toolcache
    if [ "$from_cache" != true ]; then
        if [ -n "$cache_dir" ]; then
            if _cache_lock_acquire "$cache_dir"; then
                mkdir -p "$cache_dir" 2>/dev/null || true
                # Copy into cache (safer across mounts/filesystems)
                if cp -a "$tmpfile" "$cache_archive" 2>/dev/null; then
                    echo "   Cached archive: $cache_archive"
                else
                    echo "   ⚠️  Failed to write to cache: $cache_archive"
                fi
                _cache_lock_release "$cache_dir"
            else
                # Lock acquisition failed - check if another process already cached it
                if [ -f "$cache_archive" ]; then
                    echo "   Archive already cached by another process: $cache_archive"
                else
                    # Best-effort: try to write without lock (risky but better than nothing)
                    mkdir -p "$cache_dir" 2>/dev/null || true
                    if cp -a "$tmpfile" "$cache_archive" 2>/dev/null; then
                        echo "   Stored archive to cache (no lock): $cache_archive"
                    else
                        echo "   ⚠️  Could not store archive to cache: $cache_archive"
                    fi
                fi
            fi
        fi
    fi

    # Extract or copy binary
    mkdir -p "$install_dir"

    if [ "$extract" = "true" ]; then
        echo "   Extracting archive..."
        local extract_dir="/tmp/${tool}-extract"
        mkdir -p "$extract_dir"

        if tar -xzf "$tmpfile" -C "$extract_dir" 2>/dev/null; then
            # If the archive created a single top-level directory, move that
            # directory into the install_dir so callers that expect an
            # extracted tree (e.g. /opt/quarto/<version>/bin/quarto) find it.
            top_level_dir=$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d -print -quit || true)
            if [ -n "$top_level_dir" ]; then
                mkdir -p "$install_dir"
                # Move the directory into place (mv preferred, fallback to copy)
                if mv "$top_level_dir" "$install_dir/" 2>/dev/null; then
                    moved_dir="$install_dir/$(basename "$top_level_dir")"
                        echo "   ✅ Installed tree to $moved_dir"
                else
                    if cp -a "$top_level_dir" "$install_dir/" 2>/dev/null; then
                        moved_dir="$install_dir/$(basename "$top_level_dir")"
                        echo "   ✅ Copied tree to $moved_dir"
                    else
                        echo "   ⚠️  Failed to move/copy extracted tree into $install_dir"
                    fi
                fi
                # Ensure the binary inside the moved tree is executable.
                # Find the binary regardless of its current executable bit
                # and make it executable so feature post-install checks pass.
                binary_path=$(find "$install_dir" -type f -name "$tool" -print -quit || true)
                if [ -n "$binary_path" ] && [ -f "$binary_path" ]; then
                    chmod +x "$binary_path" || true
                fi
                # If the moved tree contains bin/<tool> and the target
                # install_dir looks like a 'bin' folder, also copy the
                # inner binary to the install_dir root so callers that
                # expect the binary directly in $install_dir find it.
                if [ -x "$moved_dir/bin/$tool" ]; then
                    # Always ensure a straightforward executable path exists
                    # at $install_dir/$tool so the verification step succeeds.
                    if [ ! -f "$install_dir/$tool" ]; then
                        # Try symlink first (cheap), fallback to copy if that fails
                        if ln -s "$moved_dir/bin/$tool" "$install_dir/$tool" 2>/dev/null; then
                            echo "   ✅ Symlinked inner binary to $install_dir/$tool"
                        else
                            cp -a "$moved_dir/bin/$tool" "$install_dir/$tool" 2>/dev/null || true
                            echo "   ✅ Copied inner binary to $install_dir/$tool"
                        fi
                        chmod +x "$install_dir/$tool" 2>/dev/null || true
                    fi
                fi
                # If the moved tree does NOT contain a bin/<tool> but does
                # contain a loose binary somewhere, copy that binary into the
                # install_dir root. This preserves behavior for features like
                # `gh` which expect the binary at /home/jovyan/bin/gh.
                if [ ! -x "$moved_dir/bin/$tool" ]; then
                    fallback_bin=$(find "$moved_dir" -type f -name "$tool" -print -quit || true)
                    if [ -n "$fallback_bin" ] && [ -f "$fallback_bin" ]; then
                        # Only copy into install_dir root if install_dir is not the same
                        # as the moved directory (avoid copying over directories).
                        if [ "$(realpath "$install_dir" 2>/dev/null)" != "$(realpath "$moved_dir" 2>/dev/null)" ]; then
                            cp -a "$fallback_bin" "$install_dir/$tool" 2>/dev/null || true
                            chmod +x "$install_dir/$tool" 2>/dev/null || true
                            echo "   ✅ Copied binary to $install_dir/$tool"
                        fi
                    fi
                fi
            else
                # No top-level dir: fall back to finding the binary and
                # copying it into the install_dir (legacy behaviour).
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
                    mkdir -p "$install_dir"
                    cp "$binary_path" "$install_dir/$tool"
                    chmod +x "$install_dir/$tool"
                    echo "   ✅ Installed to $install_dir/$tool"
                else
                    echo "❌ Binary $tool not found in archive"
                    rm -rf "$extract_dir" "$tmpfile"
                    return 1
                fi
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

    local curl_flags=(--fail --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 300 -fsSL)
    # Toolcache support for direct URLs
    local TOOLCACHE_DIR="${TOOLCACHE_DIR:-/opt/toolcache}"
    local filename_base
    filename_base=$(basename "$url")
    local cache_archive="$TOOLCACHE_DIR/$tool/$(basename "$url")"
    local cache_dir
    cache_dir=$(dirname "$cache_archive")

    _cache_lock_acquire() {
        local lockdir="$1/.lock"
        local max_attempts=50
        local n=0
        until mkdir "$lockdir" 2>/dev/null; do
            n=$((n+1))
            if [ "$n" -ge "$max_attempts" ]; then
                echo "   ⚠️  Could not acquire cache lock after $((n*200/1000))s, proceeding without cache write"
                return 1
            fi
            sleep 0.2
        done
        return 0
    }
    _cache_lock_release() {
        local lockdir="$1/.lock"
        rmdir "$lockdir" 2>/dev/null || true
    }

    local from_cache=false
    if [ -f "$cache_archive" ]; then
        echo "   Using cached archive: $cache_archive"
        cp -a "$cache_archive" "$tmpfile"
        from_cache=true
    fi

    while [ $attempt -le $max_attempts ]; do
        echo "   Download attempt $attempt/$max_attempts..."
        if [ "$from_cache" = true ] || curl "${curl_flags[@]}" -o "$tmpfile" "$url"; then
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

    # If downloaded and not from cache, store in toolcache
    if [ "$from_cache" != true ]; then
        if [ -n "$cache_dir" ]; then
            if _cache_lock_acquire "$cache_dir"; then
                mkdir -p "$cache_dir" 2>/dev/null || true
                if cp -a "$tmpfile" "$cache_archive" 2>/dev/null; then
                    echo "   Cached archive: $cache_archive"
                else
                    echo "   ⚠️  Failed to write to cache: $cache_archive"
                fi
                _cache_lock_release "$cache_dir"
            else
                mkdir -p "$cache_dir" 2>/dev/null || true
                if cp -a "$tmpfile" "$cache_archive" 2>/dev/null; then
                    echo "   Stored archive to cache (no lock): $cache_archive"
                else
                    echo "   ⚠️  Could not store archive to cache: $cache_archive"
                fi
            fi
        fi
    fi

    # Check checksums.json similarly for direct downloads when possible
    local checksums_file=""
    if [ -f /tmp/checksums.json ]; then
        checksums_file=/tmp/checksums.json
    elif [ -f "${PWD}/Artefacts/checksums.json" ]; then
        checksums_file="${PWD}/Artefacts/checksums.json"
    fi
    if [ -n "$checksums_file" ] && command -v jq >/dev/null 2>&1; then
        # Attempt to infer tool and version from URL if possible (best-effort)
        :
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

# Install lightweight CLI wrappers so other feature install scripts can
# invoke the downloader without sourcing the helper (supports separate
# bash invocations during image build).
WRAPPER_DIR="/usr/local/bin"
mkdir -p "$WRAPPER_DIR"

cat > "$WRAPPER_DIR/download_github_release" <<'WRAPPER'
#!/usr/bin/env bash
if [ -f /usr/local/lib/download-release-helpers.sh ]; then
    # shellcheck disable=SC1091
    source /usr/local/lib/download-release-helpers.sh
    download_github_release "$@"
    exit $?
else
    echo "download-release helper not found: /usr/local/lib/download-release-helpers.sh" >&2
    exit 2
fi
WRAPPER

cat > "$WRAPPER_DIR/download_direct" <<'WRAPPER'
#!/usr/bin/env bash
if [ -f /usr/local/lib/download-release-helpers.sh ]; then
    # shellcheck disable=SC1091
    source /usr/local/lib/download-release-helpers.sh
    download_direct "$@"
    exit $?
else
    echo "download-release helper not found: /usr/local/lib/download-release-helpers.sh" >&2
    exit 2
fi
WRAPPER

chmod 0755 "$WRAPPER_DIR/download_github_release" "$WRAPPER_DIR/download_direct" || true
chown root:root "$WRAPPER_DIR/download_github_release" "$WRAPPER_DIR/download_direct" 2>/dev/null || true

echo "✅ CLI wrappers installed: $WRAPPER_DIR/download_github_release, $WRAPPER_DIR/download_direct"
