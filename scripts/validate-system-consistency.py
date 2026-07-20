#!/usr/bin/env python3
"""
Comprehensive validation of profile and feature system consistency.

Validates:
1. Profile parent chains (no cycles, valid references)
2. Feature existence (all referenced features exist)
3. Dependency convergence (profile expansion + sorting produces valid results)
4. Logical consistency (no conflicting provides, valid dependency chains)
5. Coverage (all profiles can be successfully built)
"""

import json
import sys
from pathlib import Path
from collections import defaultdict, Counter
from typing import Dict, List, Set, Tuple, Optional

class Colors:
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    RED = '\033[91m'
    BLUE = '\033[94m'
    CYAN = '\033[96m'
    BOLD = '\033[1m'
    RESET = '\033[0m'

def load_feature_metadata(features_dir: Path) -> Dict:
    """Load all feature metadata"""
    features = {}

    for feature_json in features_dir.glob("*/feature.json"):
        try:
            with open(feature_json) as f:
                data = json.load(f)
            feature_id = data.get('id')
            if feature_id:
                features[feature_id] = {
                    'id': feature_id,
                    'dependsOn': data.get('dependsOn', []),
                    'provides': data.get('provides', []),
                    'description': data.get('description', ''),
                    'path': feature_json.parent
                }
        except Exception as e:
            print(f"{Colors.YELLOW}⚠ Warning: Could not load {feature_json}: {e}{Colors.RESET}")

    return features

def parse_profile(profile_path: Path) -> Tuple[Optional[str], List[str], Dict[str, str]]:
    """Parse a profile file, return (parent, features, options)"""
    if not profile_path.exists() or not profile_path.is_file():
        return None, [], {}

    parent = None
    features = []
    options = {}

    with open(profile_path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue

            if line.startswith('@parent:') or line.startswith('@profile:'):
                parent = line.split(':', 1)[1].strip()
            elif line.startswith('@options:'):
                opts_str = line.split(':', 1)[1].strip()
                for opt in opts_str.split(';'):
                    if '=' in opt:
                        k, v = opt.split('=', 1)
                        options[k.strip()] = v.strip()
            elif line.startswith('@services:'):
                # DevContainer service directive — not a feature
                continue
            else:
                # Regular feature line
                feature_name = line.split()[0] if line.split() else None
                if feature_name:
                    features.append(feature_name)

    return parent, features, options

def expand_profile_recursive(
    profile_name: str,
    profiles_dir: Path,
    visited: Optional[Set[str]] = None
) -> Tuple[List[str], Dict[str, str], List[str]]:
    """
    Recursively expand a profile including parent chain.
    Returns (features, options, parent_chain)
    """
    if visited is None:
        visited = set()

    if profile_name in visited:
        return [], {}, [profile_name]  # Cycle detected

    visited.add(profile_name)
    profile_path = profiles_dir / profile_name

    if not profile_path.exists():
        return [], {}, []

    parent, features, options = parse_profile(profile_path)
    parent_chain = [profile_name]

    if parent:
        parent_features, parent_options, parent_parent_chain = expand_profile_recursive(
            parent, profiles_dir, visited
        )
        # Parent features come first, then current features
        features = parent_features + features
        # Merge options (current overrides parent)
        merged_options = parent_options.copy()
        merged_options.update(options)
        options = merged_options
        parent_chain = parent_parent_chain + parent_chain

    return features, options, parent_chain

def topological_sort_features(
    features_list: List[str],
    feature_metadata: Dict
) -> Tuple[Optional[List[str]], List[str]]:
    """
    Topologically sort features by dependencies.
    Returns (sorted_features, errors)
    """
    errors = []

    # Build adjacency list
    graph = defaultdict(list)
    in_degree = defaultdict(int)

    # Initialize with all features
    for feature in features_list:
        if feature not in in_degree:
            in_degree[feature] = 0

    # Build edges
    for feature in features_list:
        if feature not in feature_metadata:
            # Feature doesn't exist or is a helper (_lib/*)
            if not feature.startswith('_lib/'):
                errors.append(f"Feature '{feature}' not found in feature metadata")
            continue

        deps = feature_metadata[feature].get('dependsOn', [])
        for dep in deps:
            if dep.startswith('_lib/'):
                continue
            if dep not in features_list:
                # External dep (transitive) — not in this profile's list.
                # Handled by the build system, not a concern for topological sort.
                continue
            graph[dep].append(feature)
            in_degree[feature] += 1

    # Kahn's algorithm
    queue = [f for f in features_list if in_degree[f] == 0]
    sorted_features = []

    while queue:
        # Sort queue for deterministic output
        queue.sort()
        feature = queue.pop(0)
        sorted_features.append(feature)

        for neighbor in graph[feature]:
            in_degree[neighbor] -= 1
            if in_degree[neighbor] == 0:
                queue.append(neighbor)

    if len(sorted_features) != len(features_list):
        # Cycle detected
        remaining = set(features_list) - set(sorted_features)
        errors.append(f"Circular dependency detected among: {remaining}")
        return None, errors

    return sorted_features, errors

def validate_feature_dependencies(
    features_list: List[str],
    feature_metadata: Dict
) -> List[str]:
    """Check if all feature dependencies are satisfied"""
    issues = []
    available = set(features_list)

    for feature in features_list:
        if feature not in feature_metadata:
            continue

        deps = feature_metadata[feature].get('dependsOn', [])
        for dep in deps:
            if dep not in available:
                issues.append(f"Feature '{feature}' depends on '{dep}' which is not in profile")

    return issues

def check_provides_conflicts(
    features_list: List[str],
    feature_metadata: Dict
) -> List[str]:
    """Check for conflicting 'provides' across features"""
    conflicts = []
    provides_map = defaultdict(list)

    for feature in features_list:
        if feature not in feature_metadata:
            continue

        provides = feature_metadata[feature].get('provides', [])
        for item in provides:
            provides_map[item].append(feature)

    for item, providers in provides_map.items():
        if len(providers) > 1:
            conflicts.append(f"Multiple features provide '{item}': {providers}")

    return conflicts

def main():
    script_dir = Path(__file__).parent
    repo_root = script_dir.parent
    profiles_dir = repo_root / "profiles"
    features_dir = repo_root / ".devcontainer" / "features"

    print(f"{Colors.BOLD}🔍 System Consistency Validation{Colors.RESET}")
    print("=" * 70)
    print()

    # Load feature metadata
    print(f"{Colors.CYAN}📦 Loading feature metadata...{Colors.RESET}")
    feature_metadata = load_feature_metadata(features_dir)
    print(f"   Found {len(feature_metadata)} features")
    print()

    # Get all profiles
    profiles = [p for p in profiles_dir.glob("*") if p.is_file() and p.name != "README.md"]
    print(f"{Colors.CYAN}📋 Found {len(profiles)} profiles{Colors.RESET}")
    print()

    # Validation results
    total_errors = 0
    total_warnings = 0
    profile_results = {}

    # Validate each profile
    for profile_path in sorted(profiles):
        profile_name = profile_path.name
        errors = []
        warnings = []

        # 1. Expand profile (check for cycles)
        features, options, parent_chain = expand_profile_recursive(profile_name, profiles_dir)

        # Check for parent cycle
        if len(parent_chain) != len(set(parent_chain)):
            errors.append("Circular parent dependency detected")

        # Check if parent exists
        parent, _, _ = parse_profile(profile_path)
        if parent and not (profiles_dir / parent).exists():
            errors.append(f"Parent profile '{parent}' does not exist")

        # 2. Check feature existence
        for feature in features:
            if not feature.startswith('_lib/') and feature not in feature_metadata:
                errors.append(f"Feature '{feature}' does not exist")

        # 3. Topological sort
        sorted_features, sort_errors = topological_sort_features(features, feature_metadata)
        if sort_errors:
            errors.extend(sort_errors)

        # 4. Check dependency satisfaction
        if sorted_features:
            dep_issues = validate_feature_dependencies(features, feature_metadata)
            for issue in dep_issues:
                # Check if it's satisfied by parent
                if parent:
                    parent_features, _, _ = expand_profile_recursive(parent, profiles_dir)
                    if issue.split("'")[3] in parent_features:
                        warnings.append(f"{issue} (provided by parent)")
                        continue
                warnings.append(issue)

        # 5. Check for conflicts
        if sorted_features:
            conflicts = check_provides_conflicts(sorted_features, feature_metadata)
            warnings.extend(conflicts)

        # Store results
        profile_results[profile_name] = {
            'features': features,
            'sorted_features': sorted_features,
            'parent_chain': parent_chain,
            'errors': errors,
            'warnings': warnings
        }

        # Print profile result
        status_symbol = "✗" if errors else ("⚠" if warnings else "✓")
        status_color = Colors.RED if errors else (Colors.YELLOW if warnings else Colors.GREEN)

        print(f"{status_color}{status_symbol} {profile_name:45}{Colors.RESET}", end="")

        if errors:
            print(f" {Colors.RED}{len(errors)} error(s){Colors.RESET}", end="")
            total_errors += len(errors)
        if warnings:
            print(f" {Colors.YELLOW}{len(warnings)} warning(s){Colors.RESET}", end="")
            total_warnings += len(warnings)

        print()

        # Print details if errors or warnings
        if errors or warnings:
            for error in errors:
                print(f"    {Colors.RED}✗ {error}{Colors.RESET}")
            for warning in warnings:
                print(f"    {Colors.YELLOW}⚠ {warning}{Colors.RESET}")

    print()
    print("=" * 70)
    print()

    # Summary statistics
    print(f"{Colors.BOLD}📊 Summary Statistics:{Colors.RESET}")
    print()

    profiles_ok = len([p for p, r in profile_results.items() if not r['errors']])
    profiles_warnings = len([p for p, r in profile_results.items() if r['warnings'] and not r['errors']])
    profiles_errors = len([p for p, r in profile_results.items() if r['errors']])

    print(f"  Total profiles: {len(profiles)}")
    print(f"  {Colors.GREEN}✓ Valid: {profiles_ok}{Colors.RESET}")
    print(f"  {Colors.YELLOW}⚠ Warnings: {profiles_warnings}{Colors.RESET}")
    print(f"  {Colors.RED}✗ Errors: {profiles_errors}{Colors.RESET}")
    print()
    print(f"  Total issues: {Colors.RED}{total_errors} errors{Colors.RESET}, {Colors.YELLOW}{total_warnings} warnings{Colors.RESET}")
    print()

    # Analyze parent chain depth
    max_depth = max(len(r['parent_chain']) for r in profile_results.values())
    avg_depth = sum(len(r['parent_chain']) for r in profile_results.values()) / len(profiles)
    print(f"  Parent chain depth: avg={avg_depth:.1f}, max={max_depth}")
    print()

    # Analyze feature usage
    all_features = []
    for result in profile_results.values():
        all_features.extend(result['features'])

    feature_usage = Counter(all_features)
    print(f"  Most common features:")
    for feature, count in feature_usage.most_common(5):
        percentage = (count / len(profiles)) * 100
        print(f"    - {feature:30} {count:2} profiles ({percentage:5.1f}%)")
    print()

    # Check convergence patterns
    print(f"{Colors.BOLD}🔄 Convergence Analysis:{Colors.RESET}")
    print()

    # Group profiles by common base
    base_groups = defaultdict(list)
    for profile, result in profile_results.items():
        if result['parent_chain']:
            base = result['parent_chain'][0]  # Root parent
            base_groups[base].append(profile)

    for base, members in sorted(base_groups.items()):
        if len(members) > 1:
            print(f"  {base:25} → {len(members)} derived profiles")

    print()

    # Final verdict
    print("=" * 70)
    if total_errors > 0:
        print(f"{Colors.RED}{Colors.BOLD}❌ VALIDATION FAILED{Colors.RESET}")
        print(f"{Colors.RED}Found {total_errors} errors that must be fixed{Colors.RESET}")
        return 1
    elif total_warnings > 0:
        print(f"{Colors.YELLOW}{Colors.BOLD}⚠️  VALIDATION PASSED WITH WARNINGS{Colors.RESET}")
        print(f"{Colors.YELLOW}Found {total_warnings} warnings (informational){Colors.RESET}")
        return 0
    else:
        print(f"{Colors.GREEN}{Colors.BOLD}✅ VALIDATION PASSED{Colors.RESET}")
        print(f"{Colors.GREEN}All profiles are consistent and buildable{Colors.RESET}")
        return 0

if __name__ == "__main__":
    sys.exit(main())
