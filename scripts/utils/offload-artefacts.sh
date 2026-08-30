#!/usr/bin/env bash
set -euo pipefail

# offload-artefacts.sh
# Collect large artefacts (toolcaches), create tarball and manifest, and print git commands
# Usage: ./scripts/offload-artefacts.sh [--dry-run] [--dest DIR]

DRY_RUN=true
DEST_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --no-dry-run) DRY_RUN=false; shift ;;
    --dest) DEST_DIR="$2"; shift 2 ;;
    --help) echo "Usage: $0 [--dry-run] [--no-dry-run] [--dest DIR]"; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT_BASE=${DEST_DIR:-"${REPO_ROOT}/artefacts/offload"}
OUT_DIR="$OUT_BASE/toolcache-offload-$TIMESTAMP"
mkdir -p "$OUT_DIR"

echo "Scanning for toolcache and large artefacts under artefacts/..."
mapfile -t PATHS < <(find "$REPO_ROOT/artefacts" -type d -name "toolcache" 2>/dev/null || true)

if [ ${#PATHS[@]} -eq 0 ]; then
  echo "No toolcache directories found under artefacts/. Nothing to do."
  exit 0
fi

echo "Found ${#PATHS[@]} toolcache directories. Copying to $OUT_DIR"
for p in "${PATHS[@]}"; do
  rel=$(realpath --relative-to="$REPO_ROOT/artefacts" "$p") || rel="$p"
  dest="$OUT_DIR/$rel"
  mkdir -p "$(dirname "$dest")"
  echo "  - $p -> $dest"
  cp -a "$p" "$dest"
done

TARBALL="$OUT_BASE/toolcache-$TIMESTAMP.tar.gz"
echo "Creating tarball $TARBALL (this may take a while)..."
tar -C "$OUT_BASE" -czf "$TARBALL" "$(basename "$OUT_DIR")"

echo "Computing checksums..."
sha256sum "$TARBALL" > "$TARBALL.sha256"

MANIFEST_JSON="$OUT_BASE/toolcache-manifest-$TIMESTAMP.json"
cat > "$MANIFEST_JSON" <<EOF
{
  "created": "${TIMESTAMP}",
  "tarball": "$(basename "$TARBALL")",
  "sha256_file": "$(basename "$TARBALL.sha256")",
  "included_paths": [
$(for p in "${PATHS[@]}"; do printf '    "%s",
'"$p""; done | sed '$ s/,$//')
  ]
}
EOF

echo
echo "Offload bundle created:"
echo "  - tarball: $TARBALL"
echo "  - checksum: $TARBALL.sha256"
echo "  - manifest: $MANIFEST_JSON"

echo
echo "Suggested next steps (manual):"
echo "1) Upload the tarball to your chosen external storage (GitHub Release, S3, artifact server):"
echo "   - GitHub Release example: \`gh release upload <tag-or-id> $TARBALL --clobber\`"
echo "   - S3 example: \`aws s3 cp $TARBALL s3://your-bucket/artefacts/\`"
echo
echo "2) Add a small placeholder file in the repo where the artefacts were, or keep only a manifest with download URL and checksum. E.g.:"
echo "   - Create 'artefacts/<feature>/toolcache.README' that points to the external URL and includes the checksum."
echo
echo "3) Untrack files from git index (run these at repo root):"
echo "   git rm -r --cached 'artefacts/**/toolcache' || true"
echo "   git commit -m 'Remove packed toolcache artefacts from repo; add offload manifest'"

if [ "$DRY_RUN" = true ]; then
  echo
  echo "Dry run mode: no files were removed or modified. To perform the offload, re-run with --no-dry-run and then follow steps above to upload and untrack."
  exit 0
fi

echo
"--no-dry-run selected but script does not auto-remove original files. Follow the printed git commands to untrack and commit when ready."

exit 0
