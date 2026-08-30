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

# Global cache locking helpers (used by both download_github_release and download_direct)
# These provide an acquire/release API backed by flock when available,
# and a mkdir-based lock directory fallback.
_cache_with_flock() {
    local cache_dir="$1"; shift
    local cmd="$*"
    mkdir -p "$cache_dir" 2>/dev/null || true
    local lockfile="$cache_dir/.lockfile"

    if command -v flock >/dev/null 2>&1; then
        if flock -w 30 "$lockfile" bash -c "$cmd"; then
            return 0
        else
            return 1
        fi
    else
        local lockdir="$cache_dir/.lock"
        local max_attempts=150
        local n=0
        until mkdir "$lockdir" 2>/dev/null; do
            n=$((n+1))
            if [ "$n" -ge "$max_attempts" ]; then
                return 1
            fi
            sleep 0.2
        done
        bash -c "$cmd"
        rmdir "$lockdir" 2>/dev/null || true
        return 0
    fi
}

_cache_lock_acquire() {
    local cache_dir="$1"
    mkdir -p "$cache_dir" 2>/dev/null || true
    local lockfile="$cache_dir/.lockfile"

    if command -v flock >/dev/null 2>&1; then
        exec 9>"$lockfile" 2>/dev/null || return 1
        if flock -w 30 9; then
            return 0
        else
            return 1
        fi
    else
        local lockdir="$cache_dir/.lock"
        local max_attempts=150
        local n=0
        until mkdir "$lockdir" 2>/dev/null; do
            n=$((n+1))
            if [ "$n" -ge "$max_attempts" ]; then
                return 1
            fi
            sleep 0.2
        done
        return 0
    fi
}

_cache_lock_release() {
    local cache_dir="$1"
    local lockfile="$cache_dir/.lockfile"
    if command -v flock >/dev/null 2>&1; then
        exec 9>&- 2>/dev/null || true
        return 0
    else
        local lockdir="$cache_dir/.lock"
        rmdir "$lockdir" 2>/dev/null || true
        return 0
    fi
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
    # Prepare candidate filenames to tolerate alternate architecture tokens
    local candidates=()
    candidates+=("$filename")
    if [ "$arch" = "arm64" ]; then
        alt_filename="$(printf '%s' "$filename" | sed 's/arm64/aarch64/g')"
        if [ "$alt_filename" != "$filename" ]; then
            candidates+=("$alt_filename")
        fi
    elif [ "$arch" = "aarch64" ]; then
        alt_filename="$(printf '%s' "$filename" | sed 's/aarch64/arm64/g')"
        if [ "$alt_filename" != "$filename" ]; then
            candidates+=("$alt_filename")
        fi
    elif [ "$arch" = "amd64" ]; then
        alt_filename="$(printf '%s' "$filename" | sed 's/amd64/x86_64/g')"
        if [ "$alt_filename" != "$filename" ]; then
            candidates+=("$alt_filename")
        fi
    elif [ "$arch" = "x86_64" ]; then
        alt_filename="$(printf '%s' "$filename" | sed 's/x86_64/amd64/g')"
        if [ "$alt_filename" != "$filename" ]; then
            candidates+=("$alt_filename")
        fi
    fi

    # Ensure candidates are unique (simple loop)
    local uniq_candidates=()
    for c in "${candidates[@]}"; do
        skip=false
        for u in "${uniq_candidates[@]}"; do
            if [ "$u" = "$c" ]; then skip=true; break; fi
        done
        if [ "$skip" = false ]; then uniq_candidates+=("$c"); fi
    done

    echo "   Pattern: $filename_pattern"
    echo "   Candidate filenames: ${uniq_candidates[*]}"

    # Toolcache support: reuse cached archives under /opt/toolcache when available
    local TOOLCACHE_DIR="${TOOLCACHE_DIR:-/opt/toolcache}"
    local filename_base
    local cache_archive
    local cache_dir
    local candidate_base
    # Prefer any existing cached candidate filename (handles arm64 vs aarch64)
    for c in "${uniq_candidates[@]}"; do
        candidate_base=$(basename "$c")
        candidate_path="$TOOLCACHE_DIR/$tool/$version/$arch/$candidate_base"
        if [ -f "$candidate_path" ]; then
            filename_base="$candidate_base"
            cache_archive="$candidate_path"
            break
        fi
    done
    # If no existing cache found, default to first candidate for naming
    if [ -z "${cache_archive:-}" ]; then
        filename_base=$(basename "${uniq_candidates[0]}")
        cache_archive="$TOOLCACHE_DIR/$tool/$version/$arch/$filename_base"
    fi
    cache_dir=$(dirname "$cache_archive")

        # Use flock-based locking when available to coordinate cache writes.
        # Falls back to a mkdir-based lock if `flock` is missing.
        _cache_with_flock() {
            local cache_dir="$1"; shift
            local cmd="$*"
            mkdir -p "$cache_dir" 2>/dev/null || true
            local lockfile="$cache_dir/.lockfile"

            if command -v flock >/dev/null 2>&1; then
                # Use flock with a bounded wait (30s)
                # `flock -w` will return non-zero if it cannot acquire the lock
                if flock -w 30 "$lockfile" bash -c "$cmd"; then
                    return 0
                else
                    return 1
                fi
            else
                # Fallback: simple mkdir lock (best-effort)
                local lockdir="$cache_dir/.lock"
                local max_attempts=150
                local n=0
                until mkdir "$lockdir" 2>/dev/null; do
                    n=$((n+1))
                    if [ "$n" -ge "$max_attempts" ]; then
                        return 1
                    fi
                    sleep 0.2
                done
                # run critical section
                bash -c "$cmd"
                rmdir "$lockdir" 2>/dev/null || true
                return 0
            fi
        }

        # Lightweight lock helpers that other parts of the script expect.
        # These provide an acquire/release API backed by flock when
        # available, and a mkdir-based lock directory fallback.
        _cache_lock_acquire() {
            local cache_dir="$1"
            mkdir -p "$cache_dir" 2>/dev/null || true
            local lockfile="$cache_dir/.lockfile"

            if command -v flock >/dev/null 2>&1; then
                # open a file descriptor for flock; return non-zero on timeout
                exec 9>"$lockfile" 2>/dev/null || return 1
                if flock -w 30 9; then
                    return 0
                else
                    return 1
                fi
            else
                local lockdir="$cache_dir/.lock"
                local max_attempts=150
                local n=0
                until mkdir "$lockdir" 2>/dev/null; do
                    n=$((n+1))
                    if [ "$n" -ge "$max_attempts" ]; then
                        return 1
                    fi
                    sleep 0.2
                done
                return 0
            fi
        }

        _cache_lock_release() {
            local cache_dir="$1"
            local lockfile="$cache_dir/.lockfile"
            if command -v flock >/dev/null 2>&1; then
                exec 9>&- 2>/dev/null || true
                return 0
            else
                local lockdir="$cache_dir/.lock"
                rmdir "$lockdir" 2>/dev/null || true
                return 0
            fi
        }

        # If cached archive exists, use it (copy to tmpfile to avoid removing cache)
        local from_cache=false
        if [ -f "$cache_archive" ]; then
            echo "   Using cached archive: $cache_archive"
            tmpfile="/tmp/${tool}-${version}.download"
            cp -a "$cache_archive" "$tmpfile"
            from_cache=true
        fi

    # Download with retries across candidate filenames
    local tmpfile="/tmp/${tool}-${version}.download"
    local max_attempts=3
    local attempt=1

    # Use robust curl flags: fail on HTTP errors, retry transient failures,
    # set connect and overall timeouts to avoid hanging during builds.
    local curl_flags=(--fail --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 300 -fsSL)

    local chosen_candidate=""
    while [ $attempt -le $max_attempts ]; do
        echo "   Download attempt $attempt/$max_attempts..."
        # Try each candidate filename until one succeeds
        local success=false
        for cand in "${uniq_candidates[@]}"; do
            local url="https://github.com/$repo/releases/download/v${version}/$cand"
            url="$(printf '%s' "$url" | tr -d '{}')"
            echo "   Trying URL: $url"
            if [ "$from_cache" = true ] || curl "${curl_flags[@]}" -o "$tmpfile" "$url"; then
                echo "   ✅ Download successful (file: $cand)"
                chosen_candidate="$cand"
                success=true
                break
            else
                echo "   ⚠️  URL failed: $url"
            fi
        done
        if [ "$success" = true ]; then
            break
        fi
        echo "   ⚠️  Download failed for all candidates, retrying..."
        attempt=$((attempt + 1))
        sleep 2
    done

    if [ ! -f "$tmpfile" ]; then
        echo "❌ Failed to download $tool after $max_attempts attempts"
        return 1
    fi

    # If checksums.json exists in repository artefacts or /tmp, verify file integrity
    local checksums_file=""
    if [ -f /tmp/checksums.json ]; then
        checksums_file=/tmp/checksums.json
    elif [ -f "${PWD}/checksums.json" ]; then
        checksums_file="${PWD}/checksums.json"
    fi
    # Use centralized checksum resolver as the single source of truth
    if ! command -v fh_resolve_checksum >/dev/null 2>&1; then
        echo "download-release: fh_resolve_checksum not available; checksum resolution required" >&2
        rm -f "$tmpfile"
        return 1
    fi
    expected_sha=$(fh_resolve_checksum "$tool" "$version" || true)
    if [ -z "$expected_sha" ]; then
        if [ "${FH_ALLOW_MISSING_CHECKSUMS:-false}" = "true" ]; then
            echo "   ⚠️  No checksum available for $tool@$version ($arch); skipping verification due to FH_ALLOW_MISSING_CHECKSUMS=true"
        else
            echo "❌ Checksum not found for $tool@$version ($arch) via fh_resolve_checksum" >&2
            rm -f "$tmpfile"
            return 1
        fi
    else
        echo "   Verifying checksum..."
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

    # If we downloaded successfully and it didn't come from cache, store in toolcache
    if [ "$from_cache" != true ]; then
        if [ -n "$cache_dir" ]; then
            mkdir -p "$cache_dir" 2>/dev/null || true
            # If we selected a different candidate than the default, update cache path
            if [ -n "$chosen_candidate" ]; then
                filename_base=$(basename "$chosen_candidate")
                cache_archive="$TOOLCACHE_DIR/$tool/$version/$arch/$filename_base"
                cache_dir=$(dirname "$cache_archive")
            fi
            # Attempt to write under flock-protected critical section
            cache_cmd="cp -a \"$tmpfile\" \"$cache_archive\""
            if _cache_with_flock "$cache_dir" "$cache_cmd"; then
                echo "   Cached archive: $cache_archive"
            else
                # If another process already wrote it, that's fine; otherwise fall back
                if [ -f "$cache_archive" ]; then
                    echo "   Archive already cached by another process: $cache_archive"
                else
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
                # Try several candidate binary names (tool, toold) to handle
                # cases where the upstream binary is suffixed with 'd' (eg gitstatusd).
                BIN_CANDIDATES=("$tool" "${tool}d")
                binary_path=""
                for bname in "${BIN_CANDIDATES[@]}"; do
                    binary_path=$(find "$install_dir" -type f -name "$bname" -print -quit || true)
                    if [ -n "$binary_path" ]; then
                        chmod +x "$binary_path" || true
                        break
                    fi
                done
                # If the moved tree contains bin/<tool> and the target
                # install_dir looks like a 'bin' folder, also copy the
                # inner binary to the install_dir root so callers that
                # expect the binary directly in $install_dir find it.
                # Search bin/ for candidate binary names and install the first match
                BIN_CANDIDATES=("$tool" "${tool}d")
                found_bin=""
                for bname in "${BIN_CANDIDATES[@]}"; do
                    if [ -x "$moved_dir/bin/$bname" ]; then
                        found_bin="$moved_dir/bin/$bname"
                        break
                    fi
                done
                if [ -n "$found_bin" ]; then
                    if [ ! -f "$install_dir/$tool" ]; then
                        if ln -s "$found_bin" "$install_dir/$tool" 2>/dev/null; then
                            echo "   ✅ Symlinked inner binary to $install_dir/$tool"
                        else
                            cp -a "$found_bin" "$install_dir/$tool" 2>/dev/null || true
                            echo "   ✅ Copied inner binary to $install_dir/$tool"
                        fi
                        chmod +x "$install_dir/$tool" 2>/dev/null || true
                    fi
                else
                    # If no bin/<candidate> found, search the moved tree for possible binaries
                    for bname in "${BIN_CANDIDATES[@]}"; do
                        fallback_bin=$(find "$moved_dir" -type f -name "$bname" -print -quit || true)
                        if [ -n "$fallback_bin" ] && [ -f "$fallback_bin" ]; then
                            if [ "$(realpath "$install_dir" 2>/dev/null)" != "$(realpath "$moved_dir" 2>/dev/null)" ]; then
                                cp -a "$fallback_bin" "$install_dir/$tool" 2>/dev/null || true
                                chmod +x "$install_dir/$tool" 2>/dev/null || true
                                echo "   ✅ Copied binary to $install_dir/$tool"
                            fi
                            break
                        fi
                    done
                    # If still not found, try any file whose name contains the tool string
                    if [ ! -f "$install_dir/$tool" ]; then
                        fallback_bin=$(find "$moved_dir" -type f -iname "*${tool}*" -print -quit || true)
                        if [ -n "$fallback_bin" ] && [ -f "$fallback_bin" ]; then
                            if [ "$(realpath "$install_dir" 2>/dev/null)" != "$(realpath "$moved_dir" 2>/dev/null)" ]; then
                                cp -a "$fallback_bin" "$install_dir/$tool" 2>/dev/null || true
                                chmod +x "$install_dir/$tool" 2>/dev/null || true
                                echo "   ✅ Copied fuzzy-matched binary to $install_dir/$tool"
                            fi
                        fi
                    fi
                fi
            else
                # No top-level dir: fall back to finding the binary and
                # copying it into the install_dir (legacy behaviour).
                local binary_path
                BIN_CANDIDATES=("$tool" "${tool}d")
                binary_path=""
                for bname in "${BIN_CANDIDATES[@]}"; do
                    binary_path=$(find "$extract_dir" -type f -name "$bname" -executable -print -quit || true)
                    if [ -n "$binary_path" ]; then
                        break
                    fi
                    if [ -f "$extract_dir/$bname" ]; then
                        binary_path="$extract_dir/$bname"
                        break
                    elif [ -f "$extract_dir/bin/$bname" ]; then
                        binary_path="$extract_dir/bin/$bname"
                        break
                    fi
                done
                # Fuzzy match: if exact names not found, try any file containing tool name
                if [ -z "$binary_path" ]; then
                    binary_path=$(find "$extract_dir" -type f -iname "*${tool}*" -print -quit || true)
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

    # flock-backed cache writer (uses flock when available, fallback to mkdir lock)
    _cache_with_flock() {
        local cache_dir="$1"; shift
        local cmd="$*"
        mkdir -p "$cache_dir" 2>/dev/null || true
        local lockfile="$cache_dir/.lockfile"

        if command -v flock >/dev/null 2>&1; then
            if flock -w 30 "$lockfile" bash -c "$cmd"; then
                return 0
            else
                echo "   ⚠️  Could not acquire flock after 30s"
                return 1
            fi
        else
            local lockdir="$cache_dir/.lock"
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
            # run critical section
            bash -c "$cmd"
            rmdir "$lockdir" 2>/dev/null || true
            return 0
        fi
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
    elif [ -f "${PWD}/checksums.json" ]; then
        checksums_file="${PWD}/checksums.json"
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
