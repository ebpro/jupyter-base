#!/usr/bin/env python3
"""
Sort features by dependencies using topological sort.
Reads feature list from stdin (one per line), outputs sorted list.
"""

import json
import sys
from pathlib import Path
from collections import defaultdict, deque

def load_dependencies(features_dir: Path, feature_list: list) -> dict:
    """Load dependencies for the given features"""
    dependencies = {}

    for feature in feature_list:
        feature_json = features_dir / feature / "feature.json"
        if not feature_json.exists():
            continue

        try:
            with open(feature_json) as f:
                data = json.load(f)
            depends_on = data.get('dependsOn', [])
            if depends_on:
                dependencies[feature] = depends_on
        except:
            pass

    return dependencies

def topological_sort(features: list, dependencies: dict) -> list:
    """Sort features respecting dependencies using Kahn's algorithm"""
    # Build a set of features for quick lookup
    feature_set = set(features)

    # Calculate in-degrees (number of dependencies each feature has)
    in_degree = {}
    for feature in features:
        deps = dependencies.get(feature, [])
        # Only count dependencies that are actually in our feature list
        in_degree[feature] = sum(1 for d in deps if d in feature_set)

    # Start with features that have no dependencies in this list
    queue = deque([f for f in features if in_degree[f] == 0])
    sorted_features = []

    while queue:
        current = queue.popleft()
        sorted_features.append(current)

        # Find features in our list that depend on current
        for feature in features:
            if feature in sorted_features:
                continue
            deps = dependencies.get(feature, [])
            if current in deps:
                in_degree[feature] -= 1
                if in_degree[feature] == 0:
                    queue.append(feature)

    # If we couldn't sort all features, preserve original order for unsorted
    if len(sorted_features) < len(features):
        unsorted = [f for f in features if f not in sorted_features]
        # Write warning to stderr
        print(f"Warning: Could not sort all features. Unsorted: {unsorted}", file=sys.stderr)
        sorted_features.extend(unsorted)

    return sorted_features

def main():
    # Read features from stdin
    feature_list = [line.strip() for line in sys.stdin if line.strip()]

    if not feature_list:
        return 0

    # Find features directory
    script_dir = Path(__file__).parent
    repo_root = script_dir.parent
    features_dir = repo_root / ".devcontainer" / "features"

    # Load dependencies
    dependencies = load_dependencies(features_dir, feature_list)

    # Sort features
    sorted_features = topological_sort(feature_list, dependencies)

    # Output sorted features
    for feature in sorted_features:
        print(feature)

    return 0

if __name__ == "__main__":
    sys.exit(main())
