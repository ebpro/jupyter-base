#!/usr/bin/env python3
"""
Validates feature dependencies and performs topological sort
Usage: ./scripts/validate-feature-deps.py [--profile PROFILE_PATH]
"""

import json
import sys
from pathlib import Path
from collections import defaultdict, deque
from typing import Dict, List, Set

# Colors
RED = '\033[0;31m'
GREEN = '\033[0;32m'
YELLOW = '\033[1;33m'
NC = '\033[0m'

def load_features(features_dir: Path) -> tuple:
    """Load all features and their dependencies"""
    features = {}
    dependencies = defaultdict(list)

    for feature_json in features_dir.glob("*/feature.json"):
        try:
            with open(feature_json) as f:
                data = json.load(f)

            feature_id = data.get('id')
            if not feature_id:
                print(f"{YELLOW}⚠{NC}  Feature {feature_json.parent.name} has no 'id' field, skipping")
                continue

            features[feature_id] = feature_json

            depends_on = data.get('dependsOn', [])
            if depends_on:
                dependencies[feature_id] = depends_on

        except Exception as e:
            print(f"{RED}✗{NC} Error reading {feature_json}: {e}")
            return {}, {}, 1

    return features, dependencies, 0

def validate_dependencies(features: Dict, dependencies: Dict) -> int:
    """Validate that all dependencies exist"""
    errors = 0

    for feature_id, deps in dependencies.items():
        for dep in deps:
            if dep not in features:
                print(f"{RED}✗{NC} Feature '{feature_id}' depends on '{dep}' which doesn't exist")
                errors += 1

    return errors

def check_cycles(dependencies: Dict) -> int:
    """Check for circular dependencies using DFS"""
    errors = 0
    visited = set()
    rec_stack = set()

    def dfs(node, path):
        nonlocal errors
        visited.add(node)
        rec_stack.add(node)
        path = path + [node]

        for dep in dependencies.get(node, []):
            if dep not in visited:
                if dfs(dep, path):
                    return True
            elif dep in rec_stack:
                cycle = path[path.index(dep):] + [dep]
                print(f"{RED}✗{NC} Circular dependency: {' → '.join(cycle)}")
                errors += 1
                return True

        rec_stack.remove(node)
        return False

    for feature in dependencies:
        if feature not in visited:
            dfs(feature, [])

    return errors

def topological_sort(features: Dict, dependencies: Dict) -> List[str]:
    """Perform topological sort using Kahn's algorithm"""
    # Calculate in-degrees (how many dependencies each feature has)
    in_degree = {f: 0 for f in features}

    # Count dependencies for each feature
    for feature, deps in dependencies.items():
        in_degree[feature] = len(deps)

    # Start with features that have no dependencies
    queue = deque([f for f, deg in in_degree.items() if deg == 0])
    sorted_features = []

    while queue:
        current = queue.popleft()
        sorted_features.append(current)

        # Find features that depend on current and reduce their in-degree
        for feature, deps in dependencies.items():
            if current in deps and feature not in sorted_features:
                in_degree[feature] -= 1
                if in_degree[feature] == 0:
                    queue.append(feature)

    return sorted_features

def validate_profile(profile_path: Path, features: Dict, dependencies: Dict) -> tuple:
    """Validate a specific profile"""
    errors = 0
    warnings = 0

    if not profile_path.exists():
        print(f"{RED}✗{NC} Profile file not found: {profile_path}")
        return 1, 0

    # Extract features from profile
    profile_features = []
    with open(profile_path) as f:
        for line in f:
            line = line.strip()
            # Skip comments and directives
            if line.startswith('#') or line.startswith('@') or not line:
                continue
            # Extract feature name (first word)
            feature = line.split()[0]
            if feature:
                profile_features.append(feature)

    print(f"Profile includes {len(profile_features)} features")
    print()

    # Validate each feature exists
    for feature in profile_features:
        if feature not in features:
            print(f"{RED}✗{NC} Profile references unknown feature: {feature}")
            errors += 1

    # Check if ordering respects dependencies
    profile_position = {f: i for i, f in enumerate(profile_features)}

    for i, feature in enumerate(profile_features):
        for dep in dependencies.get(feature, []):
            if dep in profile_position:
                dep_pos = profile_position[dep]
                if dep_pos > i:
                    print(f"{RED}✗{NC} Dependency order violated: {feature} (pos {i}) depends on {dep} (pos {dep_pos})")
                    errors += 1
            else:
                print(f"{YELLOW}⚠{NC}  Feature {feature} depends on {dep} which is not in profile")
                warnings += 1

    return errors, warnings

def main():
    script_dir = Path(__file__).parent
    repo_root = script_dir.parent
    features_dir = repo_root / ".devcontainer" / "features"

    print("Feature Dependency Validator")
    print("=" * 30)
    print()

    # Load features
    print("📦 Discovering features...")
    features, dependencies, errors = load_features(features_dir)
    if errors:
        return 1

    print(f"Found {len(features)} features")
    print()

    # Validate dependencies
    print("🔍 Validating dependencies...")
    errors = validate_dependencies(features, dependencies)
    if errors == 0:
        print(f"{GREEN}✓{NC} All dependencies reference existing features")
    print()

    # Check for cycles
    print("🔄 Checking for circular dependencies...")
    cycle_errors = check_cycles(dependencies)
    errors += cycle_errors
    if cycle_errors == 0:
        print(f"{GREEN}✓{NC} No circular dependencies found")
    print()

    # Topological sort
    print("📊 Performing topological sort...")
    sorted_features = topological_sort(features, dependencies)

    if len(sorted_features) != len(features):
        print(f"{RED}✗{NC} Topological sort failed - possible cycle or disconnected graph")
        print(f"   Sorted {len(sorted_features)} out of {len(features)} features")
        errors += 1
    else:
        print(f"{GREEN}✓{NC} Topological sort successful")
        print()
        print("Installation order:")
        for i, feature_id in enumerate(sorted_features, 1):
            deps = dependencies.get(feature_id, [])
            if deps:
                print(f"  {i}. {feature_id} (depends on: {', '.join(deps)})")
            else:
                print(f"  {i}. {feature_id}")
    print()

    # Validate profile if specified
    warnings = 0
    if len(sys.argv) > 1 and sys.argv[1] == "--profile" and len(sys.argv) > 2:
        profile_path = Path(sys.argv[2])
        print(f"🔍 Validating profile: {profile_path}")
        print()
        prof_errors, prof_warnings = validate_profile(profile_path, features, dependencies)
        errors += prof_errors
        warnings += prof_warnings

        if prof_errors == 0:
            print(f"{GREEN}✓{NC} Profile dependency order is valid")
        print()

    # Summary
    print("Summary")
    print("-" * 30)
    print(f"Total features: {len(features)}")
    print(f"Features with dependencies: {len(dependencies)}")
    print(f"Errors: {errors}")
    print(f"Warnings: {warnings}")
    print()

    if errors > 0:
        print(f"{RED}❌ Validation failed with {errors} error(s){NC}")
        return 1
    elif warnings > 0:
        print(f"{YELLOW}⚠️  Validation passed with {warnings} warning(s){NC}")
        return 0
    else:
        print(f"{GREEN}✅ All validations passed!{NC}")
        return 0

if __name__ == "__main__":
    sys.exit(main())
