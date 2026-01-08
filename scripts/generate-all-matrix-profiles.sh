#!/bin/bash
# Generate all profiles from matrix definitions

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MATRIX_DIR="$REPO_ROOT/profiles/matrix"
OUTPUT_DIR="$REPO_ROOT/generated/profiles"

echo "🔨 Generating profiles from matrix definitions..."
echo ""

count=0
for matrix_file in "$MATRIX_DIR"/*.yaml; do
    if [[ -f "$matrix_file" ]]; then
        name=$(basename "$matrix_file" .yaml)
        echo "Processing $name..."
        python3 "$SCRIPT_DIR/generate-profiles-matrix.py" \
            --matrix "$matrix_file" \
            --out "$OUTPUT_DIR"
        ((count++))
    fi
done

echo ""
echo "✅ Processed $count matrix files"
echo "📁 Generated profiles in: $OUTPUT_DIR"
echo ""
ls -1 "$OUTPUT_DIR" | wc -l | xargs echo "Total profiles:"
