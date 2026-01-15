#!/usr/bin/env python3
"""
Generate README.md files for features based on feature.json and install.sh analysis.

Automatically extracts:
- Package names from install.sh (apt, pip, conda, npm, etc.)
- Commands being installed
- Purpose from feature.json description
"""

import json
import re
import sys
from pathlib import Path
from typing import Dict, List, Set, Optional
from dataclasses import dataclass

@dataclass
class FeatureAnalysis:
    """Analysis of a feature's installation behavior."""
    feature_id: str
    name: str
    description: str
    category: str
    installs_packages: List[str]
    installs_commands: Set[str]
    package_managers: Set[str]
    has_apt: bool
    has_pip: bool
    has_conda: bool
    has_npm: bool
    has_downloads: bool
    complexity: str
    dependencies: List[str]


class InstallScriptAnalyzer:
    """Analyzes install.sh to extract what's being installed."""

    # Package manager patterns
    APT_PATTERN = re.compile(r'apt-get install.*?(?:--yes|--assume-yes|-y)?\s+([a-z0-9\-\+\.\s]+)', re.IGNORECASE)
    PIP_PATTERN = re.compile(r'pip3?\s+install\s+([a-z0-9\-_\[\]\s,>=<.]+)', re.IGNORECASE)
    CONDA_PATTERN = re.compile(r'(?:conda|mamba)\s+install.*?\s+([a-z0-9\-_\s=]+)', re.IGNORECASE)
    NPM_PATTERN = re.compile(r'npm\s+install\s+(?:-g\s+)?([a-z0-9\-@/\s]+)', re.IGNORECASE)

    # Download patterns
    DOWNLOAD_PATTERN = re.compile(r'(?:wget|curl).*?([a-zA-Z0-9\-_.]+\.(?:tar\.gz|tgz|zip|deb|rpm))', re.IGNORECASE)
    GITHUB_RELEASE = re.compile(r'github\.com/([^/]+/[^/]+)/releases')

    # Command installation patterns
    INSTALL_BINARY = re.compile(r'install.*?/usr/(?:local/)?bin/([a-z0-9\-_]+)(?:\s|$)', re.IGNORECASE)
    COPY_BINARY = re.compile(r'(?:cp|mv).*?/usr/(?:local/)?bin/([a-z0-9\-_]+)(?:\s|$)', re.IGNORECASE)

    # Ignore list for common false positives
    IGNORE_COMMANDS = {'else', 'fi', 'then', 'do', 'done', 'if', 'case', 'esac', 'for', 'while', 'until'}

    def analyze(self, install_script_path: Path) -> Dict:
        """Analyze install.sh and extract installation details."""
        if not install_script_path.exists():
            return {
                'packages': [],
                'commands': set(),
                'package_managers': set(),
                'has_downloads': False
            }

        with open(install_script_path) as f:
            content = f.read()

        packages = []
        commands = set()
        package_managers = set()

        # Extract apt packages
        for match in self.APT_PATTERN.finditer(content):
            pkgs = match.group(1).strip()
            # Clean up package list
            pkgs = re.sub(r'\s+', ' ', pkgs)
            for pkg in pkgs.split():
                if pkg and not pkg.startswith('-'):
                    packages.append(pkg)
                    package_managers.add('apt')

        # Extract pip packages
        for match in self.PIP_PATTERN.finditer(content):
            pkgs = match.group(1).strip()
            for pkg in re.split(r'[\s,]+', pkgs):
                if pkg and not pkg.startswith('-'):
                    # Remove version specifiers
                    pkg = re.sub(r'[>=<\[].*', '', pkg)
                    if pkg:
                        packages.append(pkg)
                        package_managers.add('pip')

        # Extract conda packages
        for match in self.CONDA_PATTERN.finditer(content):
            pkgs = match.group(1).strip()
            for pkg in pkgs.split():
                if pkg and not pkg.startswith('-') and '=' not in pkg:
                    packages.append(pkg)
                    package_managers.add('conda')

        # Extract npm packages
        for match in self.NPM_PATTERN.finditer(content):
            pkgs = match.group(1).strip()
            for pkg in pkgs.split():
                if pkg:
                    packages.append(pkg)
                    package_managers.add('npm')

        # Extract command names from binary installations
        for match in self.INSTALL_BINARY.finditer(content):
            cmd = match.group(1)
            if cmd not in self.IGNORE_COMMANDS:
                commands.add(cmd)
        for match in self.COPY_BINARY.finditer(content):
            cmd = match.group(1)
            if cmd not in self.IGNORE_COMMANDS:
                commands.add(cmd)

        # Check for downloads
        has_downloads = bool(self.DOWNLOAD_PATTERN.search(content) or self.GITHUB_RELEASE.search(content))

        return {
            'packages': list(set(packages)),  # Remove duplicates
            'commands': commands,
            'package_managers': package_managers,
            'has_downloads': has_downloads
        }


class FeatureAnalyzer:
    """Analyzes a feature directory and generates README content."""

    def __init__(self):
        self.install_analyzer = InstallScriptAnalyzer()

    def analyze_feature(self, feature_path: Path) -> Optional[FeatureAnalysis]:
        """Analyze a feature and return structured data."""
        feature_json_path = feature_path / 'feature.json'
        install_script_path = feature_path / 'install.sh'

        if not feature_json_path.exists():
            return None

        # Load feature.json
        with open(feature_json_path) as f:
            feature_data = json.load(f)

        # Analyze install.sh
        install_data = self.install_analyzer.analyze(install_script_path)

        # Extract metadata
        feature_id = feature_data.get('id', feature_path.name)
        name = feature_data.get('name', feature_id)
        description = feature_data.get('description', '')

        # Get custom metadata
        solen_data = feature_data.get('customizations', {}).get('solen', {})
        category = solen_data.get('category', 'tool')
        complexity = solen_data.get('complexity', 'simple')

        # Dependencies
        dependencies = feature_data.get('dependsOn', [])

        return FeatureAnalysis(
            feature_id=feature_id,
            name=name,
            description=description,
            category=category,
            installs_packages=install_data['packages'][:20],  # Limit to first 20
            installs_commands=install_data['commands'],
            package_managers=install_data['package_managers'],
            has_apt='apt' in install_data['package_managers'],
            has_pip='pip' in install_data['package_managers'],
            has_conda='conda' in install_data['package_managers'],
            has_npm='npm' in install_data['package_managers'],
            has_downloads=install_data['has_downloads'],
            complexity=complexity,
            dependencies=dependencies
        )

    def generate_readme(self, analysis: FeatureAnalysis) -> str:
        """Generate README.md content from analysis."""
        lines = []

        # Title
        lines.append(f"# {analysis.name}\n")

        # One-line install summary
        if analysis.installs_packages or analysis.installs_commands:
            installs = []
            if analysis.installs_commands:
                installs.extend(sorted(analysis.installs_commands)[:5])
            if analysis.installs_packages and not installs:
                installs.extend(sorted(analysis.installs_packages)[:5])

            if installs:
                install_str = ', '.join(installs)
                if len(analysis.installs_packages) > 5 or len(analysis.installs_commands) > 5:
                    install_str += ', ...'
                lines.append(f"**Installs:** {install_str}\n")

        # Purpose (from description)
        if analysis.description:
            lines.append(f"**Purpose:** {analysis.description}\n")

        # Description section
        lines.append("## Description\n")

        # Generate description paragraph based on what we know
        if analysis.description:
            # Use the existing description as the primary paragraph
            lines.append(f"{analysis.description}\n")
        else:
            # Generate description from installation details
            desc_parts = []

            # What it installs
            if analysis.installs_commands:
                cmd_list = ', '.join(sorted(analysis.installs_commands)[:3])
                desc_parts.append(f"Installs and configures {cmd_list}")
            elif analysis.installs_packages:
                pkg_count = len(analysis.installs_packages)
                if pkg_count <= 3:
                    pkg_list = ', '.join(analysis.installs_packages)
                    desc_parts.append(f"Installs {pkg_list}")
                else:
                    desc_parts.append(f"Installs {pkg_count} packages including {', '.join(analysis.installs_packages[:2])}")
            elif analysis.has_downloads:
                desc_parts.append("Downloads and installs binaries from upstream sources")
            else:
                desc_parts.append("Configures system settings and environment")

            # Package managers
            if analysis.package_managers:
                managers = sorted(analysis.package_managers)
                desc_parts.append(f"using {', '.join(managers)}")

            description_text = ' '.join(desc_parts) + '.'
            lines.append(f"{description_text}\n")

        # Add complexity note
        if analysis.complexity == 'complex':
            lines.append("\n**Note:** This is a complex feature with longer installation time.\n")

        # Verification section (if commands available)
        if analysis.installs_commands:
            lines.append("\n## Verification\n")
            cmd = sorted(analysis.installs_commands)[0]
            lines.append(f"```bash\n{cmd} --version\n```\n")

        # Dependencies section
        if analysis.dependencies:
            lines.append("\n## Dependencies\n")
            for dep in analysis.dependencies:
                lines.append(f"- `{dep}`\n")

        return '\n'.join(lines)


def generate_feature_matrix(analyses: List[FeatureAnalysis]) -> str:
    """Generate feature matrix for overlap detection."""
    lines = []
    lines.append("# Feature Matrix\n")
    lines.append("## Overview by Category\n")

    # Group by category
    by_category = {}
    for analysis in analyses:
        cat = analysis.category
        if cat not in by_category:
            by_category[cat] = []
        by_category[cat].append(analysis)

    # Output by category
    for category in sorted(by_category.keys()):
        lines.append(f"\n### {category.title()}\n")
        lines.append("| Feature | Installs | Package Managers |\n")
        lines.append("|---------|----------|------------------|\n")

        for analysis in sorted(by_category[category], key=lambda a: a.feature_id):
            installs = list(analysis.installs_commands) or analysis.installs_packages[:3]
            install_str = ', '.join(sorted(installs)[:3])
            if len(installs) > 3:
                install_str += ', ...'

            pm_str = ', '.join(sorted(analysis.package_managers)) or 'manual'

            lines.append(f"| {analysis.feature_id} | {install_str} | {pm_str} |\n")

    # Potential overlaps section
    lines.append("\n## Potential Overlaps\n")

    # Group by what they install (simple heuristic)
    install_groups = {}
    for analysis in analyses:
        key_pkgs = set()
        for pkg in analysis.installs_packages[:5]:
            # Extract base package name
            base = re.sub(r'[-_]\d+.*', '', pkg.lower())
            key_pkgs.add(base)

        for cmd in list(analysis.installs_commands)[:3]:
            key_pkgs.add(cmd.lower())

        for pkg in key_pkgs:
            if pkg not in install_groups:
                install_groups[pkg] = []
            install_groups[pkg].append(analysis.feature_id)

    # Find overlaps (2+ features installing same thing)
    overlaps = {k: v for k, v in install_groups.items() if len(v) > 1}

    if overlaps:
        lines.append("| Package/Command | Features |\n")
        lines.append("|-----------------|----------|\n")
        for pkg in sorted(overlaps.keys()):
            features = ', '.join(sorted(overlaps[pkg]))
            lines.append(f"| {pkg} | {features} |\n")
    else:
        lines.append("No obvious overlaps detected.\n")

    return '\n'.join(lines)


def main():
    import argparse

    parser = argparse.ArgumentParser(
        description='Generate README.md files for features'
    )
    parser.add_argument(
        'features',
        nargs='*',
        help='Specific features to process (default: all)'
    )
    parser.add_argument(
        '--features-dir',
        type=Path,
        default=Path('features'),
        help='Path to features directory'
    )
    parser.add_argument(
        '--dry-run',
        action='store_true',
        help='Show what would be generated without writing files'
    )
    parser.add_argument(
        '--force',
        action='store_true',
        help='Overwrite existing README.md files'
    )
    parser.add_argument(
        '--matrix',
        type=Path,
        help='Generate feature matrix to this file'
    )

    args = parser.parse_args()

    # Resolve features directory
    features_dir = args.features_dir
    if not features_dir.is_absolute():
        features_dir = Path.cwd() / features_dir

    if not features_dir.exists():
        print(f"❌ Features directory not found: {features_dir}", file=sys.stderr)
        return 1

    # Determine which features to process
    if args.features:
        feature_paths = [features_dir / f for f in args.features]
        for path in feature_paths:
            if not path.exists():
                print(f"❌ Feature not found: {path}", file=sys.stderr)
                return 1
    else:
        feature_paths = sorted([
            p for p in features_dir.iterdir()
            if p.is_dir() and not p.name.startswith('.')
        ])

    if not feature_paths:
        print("⚠️  No features found", file=sys.stderr)
        return 0

    print(f"📝 Processing {len(feature_paths)} feature(s)...\n")

    # Analyze features
    analyzer = FeatureAnalyzer()
    analyses = []
    generated = 0
    skipped = 0

    for feature_path in feature_paths:
        analysis = analyzer.analyze_feature(feature_path)
        if not analysis:
            print(f"⚠️  {feature_path.name}: No feature.json, skipping")
            skipped += 1
            continue

        analyses.append(analysis)

        # Generate README
        readme_path = feature_path / 'README.md'
        readme_content = analyzer.generate_readme(analysis)

        # Check if README exists
        if readme_path.exists() and not args.force:
            print(f"⏭️  {analysis.feature_id}: README.md exists, skipping (use --force to overwrite)")
            skipped += 1
            continue

        # Dry run or write
        if args.dry_run:
            print(f"📄 {analysis.feature_id}:")
            print("─" * 60)
            print(readme_content[:300] + "...\n")
        else:
            readme_path.write_text(readme_content)
            print(f"✅ {analysis.feature_id}: README.md generated")
            generated += 1

    # Summary
    print("\n" + "="*60)
    print(f"📊 Summary:")
    print(f"   ✅ Generated: {generated}")
    print(f"   ⏭️  Skipped: {skipped}")

    # Generate feature matrix
    if args.matrix and analyses:
        matrix_content = generate_feature_matrix(analyses)
        if args.dry_run:
            print(f"\n📊 Feature Matrix Preview:")
            print(matrix_content[:500] + "...\n")
        else:
            args.matrix.write_text(matrix_content)
            print(f"   📊 Matrix: {args.matrix}")

    return 0


if __name__ == '__main__':
    sys.exit(main())
