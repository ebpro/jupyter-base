#!/usr/bin/env python3
"""
Feature Layer Analysis Tool

Analyzes all profiles to determine optimal Docker layer strategy based on
feature usage patterns. Helps optimize build times by identifying common
features that should be shared across profiles.

Usage:
    python scripts/analyze-profile-features.py
    python scripts/analyze-profile-features.py --threshold-universal 0.75
    python scripts/analyze-profile-features.py --output analysis/layers.json
"""

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path
from typing import Dict, List, Set, Tuple


class FeatureAnalyzer:
    """Analyzes feature usage across profiles to compute optimal layers."""

    def __init__(self, repo_root: Path, threshold_universal: float = 0.8,
                 threshold_common: float = 0.5):
        self.repo_root = repo_root
        self.profiles_dir = repo_root / "profiles"
        self.threshold_universal = threshold_universal
        self.threshold_common = threshold_common

        # Feature categories based on function
        self.feature_categories = {
            'base': ['user', 'base-apt', 'zsh-config', 'startup'],
            'python': ['python-base', 'python-conda', 'pip-requirements', 'python-lsp'],
            'java': ['java-sdkman', 'java-jdk', 'java-maven', 'java-gradle'],
            'jupyter': ['jupyter-base', 'jupyter-kernels', 'java-kernel'],
            'dev': ['dev-tools', 'gh-cli', 'git-lfs', 'node'],
            'quarto': ['quarto-common', 'quarto-cli', 'quarto-python'],
            'docker': ['docker-cli', 'docker-compose', 'docker-buildx', 'podman'],
            'databases': ['postgresql-client'],
            'utils': ['prompt-helpers', 'texlive'],
        }

    def find_profiles(self) -> List[Path]:
        """Find all profile files (non-matrix, regular profiles)."""
        profiles = []

        # Direct profile files
        if self.profiles_dir.exists():
            for item in self.profiles_dir.iterdir():
                if item.is_file() and not item.name.startswith('.'):
                    # Skip README and special files
                    if item.name not in ['README.md', 'README']:
                        profiles.append(item)

        return sorted(profiles)

    def parse_profile(self, profile_path: Path) -> Tuple[str, List[str], str]:
        """
        Parse a profile file to extract features.

        Returns:
            (profile_name, features_list, parent_profile)
        """
        features = []
        parent = None

        with open(profile_path, 'r') as f:
            for line in f:
                line = line.strip()

                # Skip comments and empty lines
                if not line or line.startswith('#'):
                    continue

                # Check for parent profile reference
                if line.startswith('@parent:') or line.startswith('parent:'):
                    parent = line.split(':', 1)[1].strip()
                    continue

                # Skip options and services
                if line.startswith('@options:') or line.startswith('@services:'):
                    continue

                # Feature line - could be bare feature name or bundle-*
                if not line.startswith('@'):
                    features.append(line)

        return profile_path.stem, features, parent

    def expand_bundles(self, features: List[str]) -> List[str]:
        """
        Expand bundle-* references into individual features.
        This is a simplified version - in reality, you'd read bundle definitions.
        """
        expanded = []
        bundle_map = {
            'bundle-base-full': ['user', 'base-apt', 'zsh-config', 'startup'],
            'bundle-dev-base': ['dev-tools', 'gh-cli', 'git-lfs'],
            'bundle-data-science': ['python-conda', 'jupyter-base', 'jupyter-kernels', 'python-lsp'],
            'bundle-quarto-full': ['quarto-common', 'quarto-cli', 'quarto-python', 'texlive'],
            'bundle-java-build': ['java-maven', 'java-gradle'],
            'bundle-python-db': ['postgresql-client'],
        }

        for feature in features:
            if feature.startswith('bundle-'):
                # Expand bundle
                if feature in bundle_map:
                    expanded.extend(bundle_map[feature])
                else:
                    # Unknown bundle, add as-is
                    expanded.append(feature)
            else:
                expanded.append(feature)

        return expanded

    def analyze(self) -> Dict:
        """Run complete analysis on all profiles."""
        profiles = self.find_profiles()

        if not profiles:
            print(f"⚠️  No profiles found in {self.profiles_dir}", file=sys.stderr)
            return {}

        print(f"📊 Analyzing {len(profiles)} profiles...")

        # Collect feature usage data
        profile_features = {}  # profile_name -> list of features
        feature_usage = defaultdict(set)  # feature -> set of profile names

        for profile_path in profiles:
            name, features, parent = self.parse_profile(profile_path)

            # Expand bundles
            expanded = self.expand_bundles(features)

            profile_features[name] = expanded

            # Track which profiles use each feature
            for feature in expanded:
                feature_usage[feature].add(name)

        total_profiles = len(profile_features)

        # Classify features into layers
        universal_features = set()
        common_features = set()
        specialized_features = set()

        for feature, profiles in feature_usage.items():
            usage_ratio = len(profiles) / total_profiles

            if usage_ratio >= self.threshold_universal:
                universal_features.add(feature)
            elif usage_ratio >= self.threshold_common:
                common_features.add(feature)
            else:
                specialized_features.add(feature)

        # Group features by category
        categorized_layers = self._categorize_features(
            universal_features, common_features, specialized_features
        )

        # Build dependency graph
        layer_order = self._compute_layer_order(categorized_layers)

        # Generate profile build plans
        profile_plans = {}
        for profile_name, features in profile_features.items():
            layers, specific = self._assign_profile_layers(
                features, categorized_layers
            )
            profile_plans[profile_name] = {
                'layers': layers,
                'specific_features': specific,
                'total_features': len(features)
            }

        # Compute savings estimate
        savings = self._estimate_savings(profile_features, categorized_layers)

        return {
            'metadata': {
                'total_profiles': total_profiles,
                'total_unique_features': len(feature_usage),
                'threshold_universal': self.threshold_universal,
                'threshold_common': self.threshold_common,
            },
            'feature_statistics': {
                feature: {
                    'usage_count': len(profiles),
                    'usage_ratio': round(len(profiles) / total_profiles, 3),
                    'used_by': sorted(list(profiles))
                }
                for feature, profiles in sorted(feature_usage.items(),
                                                key=lambda x: len(x[1]),
                                                reverse=True)
            },
            'layers': categorized_layers,
            'layer_build_order': layer_order,
            'profile_plans': profile_plans,
            'savings_estimate': savings,
            'recommendations': self._generate_recommendations(
                total_profiles, categorized_layers, savings
            )
        }

    def _categorize_features(self, universal: Set[str], common: Set[str],
                            specialized: Set[str]) -> Dict:
        """Group features into logical layers based on categories."""
        layers = {}

        # Base layer - always first
        base_features = universal & set(self.feature_categories.get('base', []))
        if base_features:
            layers['base'] = {
                'features': sorted(list(base_features)),
                'type': 'universal',
                'dependencies': []
            }

        # Add remaining universal features
        remaining_universal = universal - base_features
        if remaining_universal:
            layers['foundation'] = {
                'features': sorted(list(remaining_universal)),
                'type': 'universal',
                'dependencies': ['base'] if 'base' in layers else []
            }

        # Group common features by category
        for category, category_features in self.feature_categories.items():
            if category == 'base':  # Already handled
                continue

            layer_features = (common | specialized) & set(category_features)
            if layer_features:
                usage_type = 'common' if layer_features & common else 'specialized'
                layers[f'{category}-stack'] = {
                    'features': sorted(list(layer_features)),
                    'type': usage_type,
                    'dependencies': ['foundation'] if 'foundation' in layers else ['base'] if 'base' in layers else []
                }

        # Catch any uncategorized features
        all_categorized = set()
        for layer_data in layers.values():
            all_categorized.update(layer_data['features'])

        uncategorized = (universal | common | specialized) - all_categorized
        if uncategorized:
            layers['misc'] = {
                'features': sorted(list(uncategorized)),
                'type': 'specialized',
                'dependencies': ['foundation'] if 'foundation' in layers else []
            }

        return layers

    def _compute_layer_order(self, layers: Dict) -> List[str]:
        """Compute build order for layers based on dependencies."""
        order = []
        added = set()

        def add_layer(name):
            if name in added:
                return

            # Add dependencies first
            for dep in layers[name].get('dependencies', []):
                if dep in layers:
                    add_layer(dep)

            order.append(name)
            added.add(name)

        # Add all layers
        for layer_name in layers:
            add_layer(layer_name)

        return order

    def _assign_profile_layers(self, features: List[str],
                               layers: Dict) -> Tuple[List[str], List[str]]:
        """Determine which layers a profile needs and its specific features."""
        needed_layers = []
        specific_features = []

        # Build feature -> layer mapping
        feature_to_layer = {}
        for layer_name, layer_data in layers.items():
            for feature in layer_data['features']:
                feature_to_layer[feature] = layer_name

        # Categorize profile features
        for feature in features:
            if feature in feature_to_layer:
                layer = feature_to_layer[feature]
                if layer not in needed_layers:
                    needed_layers.append(layer)
            else:
                specific_features.append(feature)

        return needed_layers, specific_features

    def _estimate_savings(self, profile_features: Dict, layers: Dict) -> Dict:
        """Estimate build time and storage savings."""
        total_profiles = len(profile_features)

        # Count features in shared layers
        shared_features = sum(len(layer['features']) for layer in layers.values())

        # Estimate current build time (sequential, no layer sharing)
        avg_features_per_profile = sum(len(f) for f in profile_features.values()) / total_profiles
        current_build_time = total_profiles * avg_features_per_profile * 0.5  # 30s per feature avg

        # Estimate layered build time (shared layers built once)
        layer_build_time = shared_features * 0.5  # Build shared layers once
        specific_build_time = sum(
            len([f for f in features if not any(f in layer['features']
                                                for layer in layers.values())])
            for features in profile_features.values()
        ) * 0.5

        layered_build_time = layer_build_time + (specific_build_time / 4)  # Parallel builds

        time_savings = ((current_build_time - layered_build_time) / current_build_time) * 100

        return {
            'current_build_minutes': round(current_build_time / 60, 1),
            'layered_build_minutes': round(layered_build_time / 60, 1),
            'time_savings_percent': round(time_savings, 1),
            'shared_layers': len(layers),
            'shared_features': shared_features,
            'builds_can_parallelize': total_profiles,
        }

    def _generate_recommendations(self, total_profiles: int,
                                 layers: Dict, savings: Dict) -> List[str]:
        """Generate actionable recommendations."""
        recommendations = []

        if savings['time_savings_percent'] > 50:
            recommendations.append(
                f"🚀 High savings potential: {savings['time_savings_percent']}% "
                f"build time reduction with layered strategy"
            )

        if len(layers) > 8:
            recommendations.append(
                f"⚠️  Many layers ({len(layers)}) detected. Consider consolidating "
                f"related features to reduce complexity."
            )

        if 'base' in layers and len(layers['base']['features']) < 3:
            recommendations.append(
                "💡 Small base layer - consider merging with foundation layer"
            )

        universal_count = sum(1 for l in layers.values() if l['type'] == 'universal')
        if universal_count > 2:
            recommendations.append(
                f"🎯 {universal_count} universal layers - good candidates for "
                f"separate base image with versioning"
            )

        recommendations.append(
            f"📦 Build {len(layers)} shared layers once, then build "
            f"{total_profiles} profiles in parallel"
        )

        recommendations.append(
            "🔧 Next steps: Update Dockerfile generator to use computed layers, "
            "implement layer build script, add cache warming strategy"
        )

        return recommendations


def main():
    parser = argparse.ArgumentParser(
        description='Analyze profile features to compute optimal Docker layer strategy'
    )
    parser.add_argument(
        '--profiles-dir',
        type=Path,
        help='Path to profiles directory (default: repo_root/profiles)'
    )
    parser.add_argument(
        '--threshold-universal',
        type=float,
        default=0.8,
        help='Threshold for universal layers (default: 0.8 = 80%%)'
    )
    parser.add_argument(
        '--threshold-common',
        type=float,
        default=0.5,
        help='Threshold for common layers (default: 0.5 = 50%%)'
    )
    parser.add_argument(
        '--output',
        type=Path,
        help='Output JSON file (default: stdout)'
    )
    parser.add_argument(
        '--format',
        choices=['json', 'summary', 'both'],
        default='both',
        help='Output format (default: both)'
    )

    args = parser.parse_args()

    # Determine repo root
    script_dir = Path(__file__).parent
    repo_root = script_dir.parent

    if args.profiles_dir:
        analyzer = FeatureAnalyzer(
            args.profiles_dir.parent,
            threshold_universal=args.threshold_universal,
            threshold_common=args.threshold_common
        )
    else:
        analyzer = FeatureAnalyzer(
            repo_root,
            threshold_universal=args.threshold_universal,
            threshold_common=args.threshold_common
        )

    # Run analysis
    results = analyzer.analyze()

    if not results:
        sys.exit(1)

    # Output results
    if args.format in ['json', 'both']:
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            with open(args.output, 'w') as f:
                json.dump(results, f, indent=2)
            print(f"✅ Analysis saved to {args.output}")
        else:
            if args.format == 'json':
                print(json.dumps(results, indent=2))

    if args.format in ['summary', 'both']:
        print("\n" + "="*70)
        print("📊 FEATURE LAYER ANALYSIS SUMMARY")
        print("="*70)

        meta = results['metadata']
        print(f"\n📁 Analyzed {meta['total_profiles']} profiles")
        print(f"🔧 Found {meta['total_unique_features']} unique features")

        print(f"\n🏗️  Recommended Layer Strategy:")
        print(f"   Layers: {len(results['layers'])}")
        for layer_name in results['layer_build_order']:
            layer = results['layers'][layer_name]
            print(f"   └─ {layer_name}: {len(layer['features'])} features ({layer['type']})")

        print(f"\n💰 Estimated Savings:")
        savings = results['savings_estimate']
        print(f"   Current: {savings['current_build_minutes']} min (sequential)")
        print(f"   Layered: {savings['layered_build_minutes']} min (parallel)")
        print(f"   Savings: {savings['time_savings_percent']}% faster")

        print(f"\n💡 Recommendations:")
        for rec in results['recommendations']:
            print(f"   • {rec}")

        print("\n" + "="*70)


if __name__ == '__main__':
    main()
