#!/usr/bin/env bash
set -euo pipefail

# Fetch gitstatusd release tarballs for each arch, extract into Artefacts, and update per-feature checksums.json
# Usage: scripts/fetch-gitstatus-artifacts.sh [version]
# If version is omitted, reads from Artefacts/versions.json

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_ROOT"

VERSION=${1:-$(jq -r '.tools.gitstatus' Artefacts/versions.json)}
if [ -z "$VERSION" ] || [ "$VERSION" = "null" ]; then
  echo "No gitstatus version found in Artefacts/versions.json and none provided." >&2
  exit 1
fi

OUTDIR="${REPO_ROOT}/Artefacts/features/prompt-helpers/toolcache/gitstatus/${VERSION}"
mkdir -p "$OUTDIR"

# Default architectures to attempt. You can override by passing a space-separated list
# as the first argument, or by setting the ARCHS env var. Common arches:
#  - amd64 (x86_64)
#  - arm64 (aarch64)
#  - armv7 (armhf)
#  - ppc64le
#  - s390x
#  - riscv64
if [ -n "${1:-}" ]; then
  read -r -a ARCHS <<< "$1"
elif [ -n "${ARCHS:-}" ]; then
  read -r -a ARCHS <<< "$ARCHS"
else
  # Only attempt the two architectures we support: amd64 and arm64 (aarch64).
  ARCHS=("amd64" "arm64")
fi

declare -A SUMS

# Map common arch names to aliases used in release asset names
arch_aliases() {
  case "$1" in
    amd64) echo "amd64 x86_64" ;;
    arm64|aarch64) echo "arm64 aarch64" ;;
    armv7) echo "armv7 armhf" ;;
    ppc64le) echo "ppc64le" ;;
    s390x) echo "s390x" ;;
    riscv64) echo "riscv64" ;;
    *) echo "$1" ;;
  esac
}

# Map arch to the checksum key used by installers (prompt-helpers expects x86_64/aarch64 etc.)
checksum_key_for() {
  case "$1" in
    amd64) echo "x86_64" ;;
    x86_64) echo "x86_64" ;;
    arm64|aarch64) echo "aarch64" ;;
    armv7) echo "armv7" ;;
    ppc64le) echo "ppc64le" ;;
    s390x) echo "s390x" ;;
    riscv64) echo "riscv64" ;;
    *) echo "$1" ;;
  esac
}

for arch in "${ARCHS[@]}"; do
  found=""
  read -r -a ALIASES <<< "$(arch_aliases "$arch")"
  for a in "${ALIASES[@]}"; do
    url="https://github.com/romkatv/gitstatus/releases/download/v${VERSION}/gitstatusd-linux-${a}.tar.gz"
    tmp="/tmp/gitstatusd-${a}.tar.gz"
    echo "Trying $url -> $tmp"
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" -o "$tmp" "$url" || true
    else
      curl -fsSL -o "$tmp" "$url" || true
    fi
    if [ -s "$tmp" ]; then
      sha=$(sha256sum "$tmp" | awk '{print $1}')
      echo "Success: $a -> $sha"
      dstdir="$OUTDIR/$arch"
      mkdir -p "$dstdir"
      tar -C "$dstdir" -zx -f "$tmp" || true
      mv "$tmp" "$OUTDIR/gitstatusd-linux-${a}.tar.gz"
      SUMS[$arch]="$sha"
      found=1
      break
    else
      rm -f "$tmp" || true
    fi
  done
  if [ -z "$found" ]; then
    echo "No release asset found for arch '$arch' (tried: ${ALIASES[*]})" >&2
  fi
done

# Patch per-feature checksums.json
CHECKSUM_FILE="$REPO_ROOT/Artefacts/features/prompt-helpers/checksums.json"
if [ ! -f "$CHECKSUM_FILE" ]; then
  echo "{ \"tools\": { \"gitstatus\": { \"checksums\": {} } } }" > "$CHECKSUM_FILE"
fi

tmpfile=$(mktemp)
jq --arg v "$VERSION" \
   --arg amd "${SUMS[amd64]:-}" \
   --arg arm "${SUMS[arm64]:-}" \
   '.tools.gitstatus.checksums[$v] = {"x86_64": $amd, "aarch64": $arm}' \
   "$CHECKSUM_FILE" > "$tmpfile" && mv "$tmpfile" "$CHECKSUM_FILE"

echo "Wrote checksums to $CHECKSUM_FILE"
echo "Extracted artefacts into $OUTDIR/{${ARCHS[*]}}"

echo "Done. You can now run your smoke validation."
