#!/usr/bin/env python3
"""
Analyze profiles to identify common feature patterns and heavy features.
This helps design optimal build stage sharing strategy.
"""

import json
import sys
from pathlib import Path
from collections import defaultdict, Counter

def load_features_metadata(features_dir: Path) -> dict:
    """Load feature metadata including size indicators"""
    features_meta = {}

    for feature_json in features_dir.glob("*/feature.json"):
        try:
            with open(feature_json) as f:
                data = json.load(f)
            feature_id = data.get('id')
            if feature_id:
                features_meta[feature_id] = {
                    'provides': data.get('provides', []),
                    'dependsOn': data.get('dependsOn', []),
                    'description': data.get('description', '')
                }
        except:
            pass

    return features_meta

def expand_profile(profile_path: Path, profiles_dir: Path, visited=None) -> tuple:
    """Recursively expand a profile including parent chain"""
    if visited is None:
        visited = set()

    if profile_path.name in visited:
        return [], []
    visited.add(profile_path.name)

    features = []
    options = []

    if not profile_path.exists():
        return features, options

    with open(profile_path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue

            if line.startswith('@parent:') or line.startswith('@profile:'):
                parent_name = line.split(':', 1)[1].strip()
                parent_path = profiles_dir / parent_name
                parent_features, parent_options = expand_profile(parent_path, profiles_dir, visited)
                features.extend(parent_features)
                options.extend(parent_options)
            elif line.startswith('@options:'):
                options.append(line)
            else:
                # Regular feature line
                feature_name = line.split()[0]
                if feature_name:
                    features.append(feature_name)

    return features, options

def analyze_profiles(profiles_dir: Path, features_dir: Path):
    """Analyze all profiles for common patterns"""

    print("🔍 Analyzing Profile Patterns")
    print("=" * 60)
    print()

    # Load feature metadata
    features_meta = load_features_metadata(features_dir)

    # Analyze each profile
    profiles_data = {}
    all_features = Counter()

    for profile_file in sorted(profiles_dir.glob("*")):
        if not profile_file.is_file() or profile_file.name == "README.md":
            continue

        profile_name = profile_file.name
        features, options = expand_profile(profile_file, profiles_dir)

        profiles_data[profile_name] = {
            'features': features,
            'feature_count': len(features),
            'unique_features': list(set(features))
        }

        # Count feature usage across profiles
        for feature in features:
            all_features[feature] += 1

    # Identify most common features (potential for shared stages)
    print("📊 Most Common Features (across all profiles):")
    print()
    for feature, count in all_features.most_common(15):
        percentage = (count / len(profiles_data)) * 100
        print(f"  {feature:30} used by {count:2} profiles ({percentage:5.1f}%)")

    print()
    print()

    # Identify "heavy" features (likely expensive to build)
    heavy_features = {
        'python-conda': 'Miniforge install (~500MB)',
        'java-devtools': 'SDKMAN + JDK + Maven (~300MB)',
        'java-sdkman': 'SDKMAN framework (~50MB)',
        'node': 'Node.js + npm (~100MB)',
        'texlive': 'TeXLive packages (~200MB+)',
        'python-base': 'System Python3 (~100MB)',
        'zsh-config': 'Prezto + themes (~50MB)',
        'jupyter-kernels': 'Multiple kernel installs (~50MB)',
        'quarto': 'Quarto CLI binary (~100MB)',
        'graalvm': 'GraalVM distribution (~400MB)',
    }

    print("⚡ Heavy Features (expensive to install):")
    print()
    for feature, description in heavy_features.items():
        if feature in all_features:
            count = all_features[feature]
            percentage = (count / len(profiles_data)) * 100
            print(f"  {feature:20} - {description:40} ({count} profiles, {percentage:5.1f}%)")

    print()
    print()

    # Analyze profile groups by feature patterns
    print("🏗️  Profile Grouping Analysis:")
    print()

    # Group 1: Python-based (has python-conda)
    python_profiles = [p for p, d in profiles_data.items()
                       if 'python-conda' in d['features']]
    print(f"  Python Stack Profiles ({len(python_profiles)}):")
    for p in sorted(python_profiles)[:5]:
        print(f"    - {p}")
    if len(python_profiles) > 5:
        print(f"    ... and {len(python_profiles) - 5} more")

    print()

    # Group 2: Java-based (has java-devtools or java-sdkman)
    java_profiles = [p for p, d in profiles_data.items()
                     if 'java-devtools' in d['features'] or 'java-sdkman' in d['features']]
    print(f"  Java Stack Profiles ({len(java_profiles)}):")
    for p in sorted(java_profiles)[:5]:
        print(f"    - {p}")
    if len(java_profiles) > 5:
        print(f"    ... and {len(java_profiles) - 5} more")

    print()

    # Group 3: Node-based (has node)
    node_profiles = [p for p, d in profiles_data.items()
                     if 'node' in d['features']]
    print(f"  Node Stack Profiles ({len(node_profiles)}):")
    for p in sorted(node_profiles)[:5]:
        print(f"    - {p}")
    if len(node_profiles) > 5:
        print(f"    ... and {len(node_profiles) - 5} more")

    print()
    print()

    # Recommend shared stages
    print("💡 Recommended Shared Build Stages:")
    print()

    # Calculate benefit of shared stages
    if python_profiles:
        print(f"  1. common-python (FROM base)")
        print(f"     Features: user, base-apt, python-base, python-conda")
        print(f"     Benefits: {len(python_profiles)} profiles ({len(python_profiles)/len(profiles_data)*100:.0f}%)")
        print(f"     Estimated: Saves ~500MB x {len(python_profiles)-1} = ~{(len(python_profiles)-1)*0.5:.1f}GB cache")
        print()

    if java_profiles:
        print(f"  2. common-java (FROM base)")
        print(f"     Features: user, base-apt, java-sdkman, java-devtools")
        print(f"     Benefits: {len(java_profiles)} profiles ({len(java_profiles)/len(profiles_data)*100:.0f}%)")
        print(f"     Estimated: Saves ~300MB x {len(java_profiles)-1} = ~{(len(java_profiles)-1)*0.3:.1f}GB cache")
        print()

    if node_profiles:
        print(f"  3. common-node (FROM base)")
        print(f"     Features: user, base-apt, node")
        print(f"     Benefits: {len(node_profiles)} profiles ({len(node_profiles)/len(profiles_data)*100:.0f}%)")
        print(f"     Estimated: Saves ~100MB x {len(node_profiles)-1} = ~{(len(node_profiles)-1)*0.1:.1f}GB cache")
        print()

    # Combined Python+Java profiles (optimal for data science)
    python_java = [p for p in python_profiles if p in java_profiles]
    if python_java:
        print(f"  4. common-python-java (FROM common-python)")
        print(f"     Additional: java-sdkman, java-devtools")
        print(f"     Benefits: {len(python_java)} profiles ({len(python_java)/len(profiles_data)*100:.0f}%)")
        print(f"     Use case: Data science + JVM languages")
        print()

    print()
    print("📈 Estimated Performance Impact:")
    print()
    total_profiles = len(profiles_data)
    cached_profiles = len(set(python_profiles + java_profiles + node_profiles))
    cache_hit_rate = (cached_profiles / total_profiles) * 100

    print(f"  Total profiles: {total_profiles}")
    print(f"  Profiles benefiting from shared stages: {cached_profiles} ({cache_hit_rate:.0f}%)")
    print(f"  Estimated build time reduction: 60-80% for cached profiles")
    print(f"  Estimated cache space saved: ~{(len(python_profiles)*0.5 + len(java_profiles)*0.3 + len(node_profiles)*0.1):.1f}GB")

    print()
    print("=" * 60)

    return profiles_data, all_features

def main():
    script_dir = Path(__file__).parent
    repo_root = script_dir.parent
    profiles_dir = repo_root / "profiles"
    features_dir = repo_root / ".devcontainer" / "features"

    analyze_profiles(profiles_dir, features_dir)

    return 0

if __name__ == "__main__":
    sys.exit(main())
