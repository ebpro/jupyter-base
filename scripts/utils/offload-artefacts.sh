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
OUT_BASE=${DEST_DIR:-"${REPO_ROOT}/Artefacts/offload"}
OUT_DIR="$OUT_BASE/toolcache-offload-$TIMESTAMP"
mkdir -p "$OUT_DIR"

echo "Scanning for toolcache and large artefacts under Artefacts/..."
mapfile -t PATHS < <(find "$REPO_ROOT/Artefacts" -type d -name "toolcache" 2>/dev/null || true)

if [ ${#PATHS[@]} -eq 0 ]; then
  echo "No toolcache directories found under Artefacts/. Nothing to do."
  exit 0
fi

echo "Found ${#PATHS[@]} toolcache directories. Copying to $OUT_DIR"
for p in "${PATHS[@]}"; do
  rel=$(realpath --relative-to="$REPO_ROOT/Artefacts" "$p") || rel="$p"
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
echo "   - Create 'Artefacts/<feature>/toolcache.README' that points to the external URL and includes the checksum."
echo
echo "3) Untrack files from git index (run these at repo root):"
echo "   git rm -r --cached 'Artefacts/**/toolcache' || true"
echo "   git commit -m 'Remove packed toolcache artefacts from repo; add offload manifest'"

if [ "$DRY_RUN" = true ]; then
  echo
  echo "Dry run mode: no files were removed or modified. To perform the offload, re-run with --no-dry-run and then follow steps above to upload and untrack."
  exit 0
fi

echo
echo "--no-dry-run selected but script does not auto-remove original files. Follow the printed git commands to untrack and commit when ready."

exit 0
#!/usr/bin/env bash
set -euo pipefail

# offload-artefacts.sh
# Archive and remove large or binary artefacts from the repo, leaving metadata behind.
# Usage: ./scripts/offload-artefacts.sh [paths...]
# If no paths are provided, defaults to: conda TeXLive features/toolcache

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_ROOT"

BACKUP_DIR="${REPO_ROOT}/../jupyter-base-artefacts-backup-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"

TARGETS=(${@:-conda TeXLive features/toolcache})

echo "Backing up: ${TARGETS[*]} -> $BACKUP_DIR"
tar -czf "$BACKUP_DIR" $(for p in "${TARGETS[@]}"; do echo "Artefacts/$p"; done) || true

echo "Removing artefacts from repository (will create placeholders)..."
for p in "${TARGETS[@]}"; do
  target="Artefacts/$p"
  if [ -e "$target" ]; then
    rm -rf "$target"
    mkdir -p "$(dirname "$target")"
    cat > "$target" <<EOF
This artefact was offloaded from the repository on $(date -u).
The real data has been archived in: $BACKUP_DIR

Fetch on-demand using `./scripts/fetch-artefact.sh` and the configured ARTIFACT_BASE_URL.
EOF
    echo "Replaced $target with placeholder"
  else
    echo "Not present: $target"
  fi
done

echo "Done. Please commit the removals. The backup tarball is located outside the repo: $BACKUP_DIR"
