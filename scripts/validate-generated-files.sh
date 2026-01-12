#!/bin/bash
# CI validation script to ensure generated files are up-to-date

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "🔍 Validating generated files are up-to-date..."
echo ""

# Store git status before generation
git_dirty_before=$(git status --porcelain | wc -l)

echo "📊 Step 1: Regenerate matrix profiles from YAML definitions"
bash "$SCRIPT_DIR/generate-all-matrix-profiles.sh"

echo ""
echo "🐳 Step 2: Regenerate all devcontainer configurations"
bash "$SCRIPT_DIR/generate-all-devcontainers.sh"

echo ""
echo "🏗️  Step 3: Regenerate Dockerfile for all profiles"
bash "$SCRIPT_DIR/generate-dockerfile.sh" --all-profiles --out "$REPO_ROOT/generated/Dockerfile"

echo ""
echo "📝 Step 4: Check for uncommitted changes in generated files"

# Check if generated files have changed
git_diff=$(git diff --name-only generated/ generated/Dockerfile 2>/dev/null || true)

if [ -n "$git_diff" ]; then
    echo ""
    echo "❌ ERROR: Generated files are out of date!"
    echo ""
    echo "The following files have changes after regeneration:"
    echo "$git_diff" | while read -r file; do
        echo "  - $file"
    done
    echo ""
    echo "To fix this issue, run locally:"
    echo "  ./scripts/generate-all-matrix-profiles.sh"
    echo "  ./scripts/generate-all-devcontainers.sh"
    echo "  ./scripts/generate-dockerfile.sh --all-profiles --out generated/Dockerfile"
    echo ""
    echo "Then commit the changes:"
    echo "  git add generated/ generated/Dockerfile"
    echo "  git commit -m 'chore: regenerate profiles and devcontainers'"
    echo ""
    exit 1
else
    echo ""
    echo "✅ All generated files are up-to-date"
    echo ""
fi

# Validate feature dependencies
echo "🔗 Step 5: Validate feature dependencies"
if [ -f "$SCRIPT_DIR/validate-feature-deps.py" ]; then
    python3 "$SCRIPT_DIR/validate-feature-deps.py" || {
        echo "❌ Feature validation failed"
        exit 1
    }
else
    echo "⚠️  Feature validation script not found, skipping"
fi

echo ""
echo "✅ All validations passed!"
echo ""
