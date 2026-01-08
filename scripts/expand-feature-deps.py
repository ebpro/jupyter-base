#!/usr/bin/env python3
"""
Expand feature dependencies recursively.
Reads feature list from stdin (one per line), outputs expanded and deduplicated list.
Resolves bundle meta-features by recursively expanding their dependsOn.
"""

import json
import sys
from pathlib import Path
from collections import deque

def load_feature_info(features_dir: Path, feature_id: str) -> dict:
    """Load feature.json for a given feature"""
    # Handle nested features like _lib/toolcache
    feature_path = features_dir / feature_id / "feature.json"

    if not feature_path.exists():
        print(f"Warning: feature.json not found for {feature_id}", file=sys.stderr)
        return {}

    try:
        with open(feature_path) as f:
            return json.load(f)
    except Exception as e:
        print(f"Warning: Could not read {feature_path}: {e}", file=sys.stderr)
        return {}

def expand_dependencies(features_dir: Path, feature_list: list) -> list:
    """
    Recursively expand feature dependencies.
    Returns a deduplicated list in dependency order (dependencies first).
    Excludes bundle meta-features from the final list (they have no install logic).
    """
    visited = set()
    expanded = []
    bundles = set()  # Track bundle meta-features to exclude

    def visit(feature_id: str):
        if feature_id in visited:
            return

        visited.add(feature_id)

        # Load feature info
        feature_data = load_feature_info(features_dir, feature_id)
        depends_on = feature_data.get('dependsOn', [])

        # If this feature has dependencies, it's likely a bundle meta-feature
        # Mark it for exclusion from final list
        if depends_on and feature_id.startswith('bundle-'):
            bundles.add(feature_id)

        # Recursively visit dependencies first (depth-first)
        for dep in depends_on:
            visit(dep)

        # Add current feature after its dependencies
        expanded.append(feature_id)

    # Process all features in input list
    for feature in feature_list:
        visit(feature)

    # Filter out bundle meta-features
    return [f for f in expanded if f not in bundles]

def main():
    # Read features from stdin
    feature_list = [line.strip() for line in sys.stdin if line.strip()]

    if not feature_list:
        return 0

    # Find features directory
    script_dir = Path(__file__).parent
    repo_root = script_dir.parent
    features_dir = repo_root / ".devcontainer" / "features"

    # Expand dependencies
    expanded_features = expand_dependencies(features_dir, feature_list)

    # Output expanded features (already in dependency order)
    for feature in expanded_features:
        print(feature)

    return 0

if __name__ == "__main__":
    sys.exit(main())
