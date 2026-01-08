#!/bin/bash
# Generate devcontainer configs for all profiles

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "🔨 Generating devcontainer configs for all profiles..."
echo ""

count=0
failed=0

# Generate from matrix profiles first
for profile in "$REPO_ROOT/generated/profiles"/*; do
    if [[ -f "$profile" ]]; then
        name=$(basename "$profile")
        echo "[$((count+1))] $name (from matrix)"
        if python3 "$SCRIPT_DIR/generate-devcontainer-json.py" "$name" 2>&1 | grep -q "Generated:"; then
            ((count++))
        else
            echo "  ⚠️  Failed"
            ((failed++))
        fi
    fi
done

# Then generate from hand-written profiles
for profile in "$REPO_ROOT/profiles"/*; do
    if [[ -f "$profile" ]]; then
        name=$(basename "$profile")
        # Skip if already generated from matrix
        if [[ ! -f "$REPO_ROOT/generated/profiles/$name" ]]; then
            echo "[$((count+1))] $name (hand-written)"
            if python3 "$SCRIPT_DIR/generate-devcontainer-json.py" "$name" 2>&1 | grep -q "Generated:"; then
                ((count++))
            else
                echo "  ⚠️  Failed"
                ((failed++))
            fi
        fi
    fi
done

echo ""
echo "✅ Generated $count devcontainer configs"
if [[ $failed -gt 0 ]]; then
    echo "⚠️  $failed profiles failed"
fi
echo "📁 Output directory: generated/devcontainer/"
echo ""
ls -1 "$REPO_ROOT/generated/devcontainer" | wc -l | xargs echo "Total configs:"
