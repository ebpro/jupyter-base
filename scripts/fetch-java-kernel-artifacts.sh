#!/usr/bin/env bash
set -euo pipefail

# Fetch IJava / java-kernel release tarball(s) for each supported arch/version,
# extract into Artefacts and write per-feature checksums.
# Usage: scripts/fetch-java-kernel-artifacts.sh [version]
# If version omitted, reads from Artefacts/versions.json at .tools.java-kernel

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_ROOT"

VERSION=${1:-$(jq -r '.tools["java-kernel"]' Artefacts/versions.json)}
if [ -z "$VERSION" ] || [ "$VERSION" = "null" ]; then
  echo "No java-kernel version found in Artefacts/versions.json and none provided." >&2
  exit 1
fi

OUTDIR="$REPO_ROOT/artefacts/java-kernel/toolcache/java-kernel/${VERSION}"
mkdir -p "$OUTDIR"

# Candidate asset names to try (common naming variations)
ASSETS=(
  "IJava-latest.zip"
  "IJava-${VERSION}.zip"
  "IJava-${VERSION}.tar.gz"
  "java-kernel-${VERSION}.tar.gz"
  "ijava-kernel-${VERSION}.tar.gz"
  "ijava-${VERSION}.tar.gz"
  "ijava-kernel-${VERSION}.zip"
  "ijava-${VERSION}.zip"
)

BASE_URL=${ARTIFACTS_BASE_URL:-"https://github.com/ebpro/IJava/releases/download"}

SUM=""
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

for asset in "${ASSETS[@]}"; do
  for tagprefix in "v${VERSION}" "${VERSION}"; do
    url="$BASE_URL/${tagprefix}/${asset}"
    tmpfile="$tmpdir/${asset}"
    echo "Trying $url -> $tmpfile"
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" -o "$tmpfile" "$url" || true
    else
      curl -fsSL -o "$tmpfile" "$url" || true
    fi
    if [ -s "$tmpfile" ]; then
      sha=$(sha256sum "$tmpfile" | awk '{print $1}')
      echo "Success: downloaded $asset -> $sha"
      mkdir -p "$OUTDIR"
      mv "$tmpfile" "$OUTDIR/$asset"
      # Try to extract into a versioned folder
      mkdir -p "$OUTDIR/extracted"
      if [[ "$asset" == *.zip ]]; then
        unzip -q "$OUTDIR/$asset" -d "$OUTDIR/extracted" || true
      else
        tar -C "$OUTDIR/extracted" -xzf "$OUTDIR/$asset" || true
      fi
      SUM="$sha"
      break 2
    else
      rm -f "$tmpfile" || true
    fi
  done
done

if [ -z "$SUM" ]; then
  echo "No release asset found for java-kernel v${VERSION}." >&2
  exit 1
fi

# Write a simple checksums.json for the feature
CHECKSUM_FILE="$REPO_ROOT/artefacts/java-kernel/checksums.json"
jq -n --arg v "$VERSION" --arg s "$SUM" '{"checksums": {($v): {"sha256": $s}}}' > "$CHECKSUM_FILE"

echo "Wrote artifact and checksums to $OUTDIR and $CHECKSUM_FILE"
echo "Done. You can now include the Artefacts directory or bind-mount it when building the image."
