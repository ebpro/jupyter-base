"""Feature dependency resolution and sorting."""

from __future__ import annotations

import json
from collections import deque
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass
class FeatureMetadata:
    """Feature metadata from feature.json."""
    id: str
    name: str
    version: str
    description: str
    depends_on: list[str]
    provides: list[str]
    options: dict[str, Any]
    maintainer: str | dict[str, str] | None
    platforms: list[str]

    @classmethod
    def load(cls, feature_dir: Path) -> FeatureMetadata:
        """Load feature metadata from feature.json."""
        feature_json = feature_dir / 'feature.json'

        with open(feature_json, encoding='utf-8') as f:
            data = json.load(f)

        # Extract maintainer info
        maintainer = data.get('maintainer')
        if isinstance(maintainer, dict):
            name = maintainer.get('name', '')
            email = maintainer.get('email', '')
            maintainer = f"{name} ({email})" if name and email else name or email

        return cls(
            id=data['id'],
            name=data['name'],
            version=data['version'],
            description=data.get('description', ''),
            depends_on=data.get('dependsOn', []),
            provides=data.get('provides', []),
            options=data.get('options', {}),
            maintainer=maintainer,
            platforms=data.get('platforms', [])
        )


def load_feature_metadata(features_dir: Path, feature_id: str) -> FeatureMetadata | None:
    """Load feature metadata, return None if not found."""
    feature_path = features_dir / feature_id
    feature_json = feature_path / 'feature.json'

    if not feature_json.exists():
        return None

    try:
        return FeatureMetadata.load(feature_path)
    except Exception:
        return None


def expand_feature_dependencies(features_dir: Path, feature_list: list[str]) -> list[str]:
    """Expand feature dependencies recursively.

    Resolves bundle meta-features by recursively expanding their dependsOn.
    Returns deduplicated list in dependency order (dependencies first).
    Excludes bundle meta-features from the final list.

    Args:
        features_dir: Path to features directory
        feature_list: List of feature IDs to expand

    Returns:
        Expanded and deduplicated list of feature IDs
    """
    visited: set[str] = set()
    expanded: list[str] = []
    bundles: set[str] = set()  # Track bundle meta-features to exclude

    def visit(feature_id: str) -> None:
        if feature_id in visited:
            return

        visited.add(feature_id)

        # Load feature metadata
        metadata = load_feature_metadata(features_dir, feature_id)
        if not metadata:
            # Feature not found, but keep it in the list (might be a typo or missing feature)
            expanded.append(feature_id)
            return

        depends_on = metadata.depends_on

        # If this feature has dependencies and starts with 'bundle-', it's a meta-feature
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

    # Filter out bundle meta-features (they have no install logic)
    return [f for f in expanded if f not in bundles]


def topological_sort_features(features_dir: Path, feature_list: list[str]) -> list[str]:
    """Sort features by dependencies using topological sort.

    Uses Kahn's algorithm to ensure dependencies are installed before dependents.

    Args:
        features_dir: Path to features directory
        feature_list: List of feature IDs to sort

    Returns:
        Sorted list of feature IDs
    """
    # Load dependencies for all features
    dependencies: dict[str, list[str]] = {}
    for feature_id in feature_list:
        metadata = load_feature_metadata(features_dir, feature_id)
        if metadata and metadata.depends_on:
            dependencies[feature_id] = metadata.depends_on

    # Build a set for quick lookup
    feature_set = set(feature_list)

    # Calculate in-degrees (number of dependencies each feature has within our list)
    in_degree: dict[str, int] = {}
    for feature in feature_list:
        deps = dependencies.get(feature, [])
        # Only count dependencies that are actually in our feature list
        in_degree[feature] = sum(1 for d in deps if d in feature_set)

    # Start with features that have no dependencies in this list
    queue: deque[str] = deque([f for f in feature_list if in_degree[f] == 0])
    sorted_features: list[str] = []

    while queue:
        current = queue.popleft()
        sorted_features.append(current)

        # Find features in our list that depend on current
        for feature in feature_list:
            if feature in sorted_features:
                continue
            deps = dependencies.get(feature, [])
            if current in deps:
                in_degree[feature] -= 1
                if in_degree[feature] == 0:
                    queue.append(feature)

    # If we couldn't sort all features, preserve original order for unsorted
    if len(sorted_features) < len(feature_list):
        unsorted = [f for f in feature_list if f not in sorted_features]
        sorted_features.extend(unsorted)

    return sorted_features


def collect_feature_metadata(features_dir: Path, feature_list: list[str]) -> dict[str, list[str]]:
    """Collect aggregated metadata from features.

    Returns dict with keys: maintainers, platforms, provides
    """
    maintainers: set[str] = set()
    platforms: set[str] = set()
    provides: set[str] = set()

    for feature_id in feature_list:
        metadata = load_feature_metadata(features_dir, feature_id)
        if not metadata:
            continue

        maintainer = metadata.maintainer
        if isinstance(maintainer, dict):
            name = maintainer.get('name', '')
            email = maintainer.get('email', '')
            maintainer = f"{name} ({email})" if name and email else name or email
        if maintainer:
            maintainers.add(maintainer)

        platforms.update(metadata.platforms)
        provides.update(metadata.provides)

    return {
        'maintainers': sorted(maintainers),
        'platforms': sorted(platforms),
        'provides': sorted(provides),
    }


def collect_post_install_checks(features_dir: Path, feature_list: list[str]) -> list[dict[str, str]]:
    """Collect postInstallCheck commands from features in install order."""
    checks: list[dict[str, str]] = []
    seen: set[str] = set()

    for feature_id in feature_list:
        if feature_id in seen:
            continue
        seen.add(feature_id)

        feature_json = features_dir / feature_id / 'feature.json'
        if not feature_json.exists():
            continue

        try:
            data = json.loads(feature_json.read_text(encoding='utf-8'))
        except Exception:
            continue

        check = data.get('postInstallCheck')
        if not isinstance(check, dict):
            continue

        command = check.get('command')
        if isinstance(command, str) and command.strip():
            checks.append({
                'id': feature_id,
                'command': command.strip(),
                'description': str(check.get('description', '')),
            })

    return checks


def collect_feature_options(features_dir: Path, feature_list: list[str]) -> dict[str, str]:
    """Collect default option values from all features.

    Returns dict of option_name -> default_value
    """
    options: dict[str, str] = {}

    for feature_id in feature_list:
        metadata = load_feature_metadata(features_dir, feature_id)
        if not metadata:
            continue

        for opt_name, opt_def in metadata.options.items():
            if isinstance(opt_def, dict) and 'default' in opt_def:
                default = opt_def['default']
                # Convert to string
                if isinstance(default, bool):
                    default = 'true' if default else 'false'
                elif default is not None:
                    default = str(default)
                else:
                    default = ''
                options[opt_name] = default

    return options
