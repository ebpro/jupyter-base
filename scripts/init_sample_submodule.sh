#!/usr/bin/env bash
set -euo pipefail

# init_sample_submodule.sh
#
# Create a local bare repository for the sample project and add it as a git submodule
# in the current repository. This is useful for creating a self-contained example
# submodule without requiring an external remote.
#
# Usage:
#   ./scripts/init_sample_submodule.sh
# Options:
#   --bare-dir DIR    Directory to create the bare repo (default: submodules/sample-quarto.git)
#   --path PATH       Path where the submodule will be added in this repo (default: examples/sample-quarto-submodule)
#   --source DIR      Source directory to publish as the submodule (default: examples/sample-quarto)

BARE_DIR="submodules/sample-quarto.git"
SUBMODULE_PATH="examples/sample-quarto-submodule"
SOURCE_DIR="examples/sample-quarto"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bare-dir)
      BARE_DIR="$2"; shift 2 ;;
    --path)
      SUBMODULE_PATH="$2"; shift 2 ;;
    --source)
      SOURCE_DIR="$2"; shift 2 ;;
    *)
      echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

echo "Using source: $SOURCE_DIR"
echo "Bare repo: $BARE_DIR"
echo "Submodule path: $SUBMODULE_PATH"

if [[ ! -d "$SOURCE_DIR" ]]; then
  echo "Source directory does not exist: $SOURCE_DIR" >&2
  exit 1
fi

# Create a bare repo if it doesn't exist
if [[ ! -d "$BARE_DIR" ]]; then
  mkdir -p "$(dirname "$BARE_DIR")"
  git init --bare "$BARE_DIR"
  echo "Created bare repo: $BARE_DIR"
fi

TMP_CLONE="/tmp/sample-quarto-clone-$$"
rm -rf "$TMP_CLONE"
git clone "$BARE_DIR" "$TMP_CLONE"
git -C "$TMP_CLONE" config user.email "bot@example.local" || true
git -C "$TMP_CLONE" config user.name "example-bot" || true

# Copy source files into temporary clone and commit
cp -a "$SOURCE_DIR/." "$TMP_CLONE/"
git -C "$TMP_CLONE" add --all
if git -C "$TMP_CLONE" diff --staged --quiet; then
  echo "No changes to commit in temporary clone"
else
  git -C "$TMP_CLONE" commit -m "Add sample-quarto project"
  git -C "$TMP_CLONE" push origin master
fi

rm -rf "$TMP_CLONE"

# Add submodule pointing to the bare repo (use relative path)
git submodule add "$BARE_DIR" "$SUBMODULE_PATH"
git add .gitmodules "$SUBMODULE_PATH"
git commit -m "Add sample-quarto submodule at $SUBMODULE_PATH" || true

echo "Submodule added at: $SUBMODULE_PATH"
echo "If you want to push the parent repo, run: git push origin HEAD"
