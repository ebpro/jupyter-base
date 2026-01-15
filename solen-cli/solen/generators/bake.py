"""Docker Bake file generator."""

import re
from datetime import datetime
from pathlib import Path
from typing import TextIO

from solen.utils.git import get_version_tags, get_git_sha


def generate_bake(
    repo_root: Path,
    output_path: Path,
    platforms: list[str] | None = None,
    repo: str = "ghcr.io/ebpro",
    image_name: str = "solen",
    include_build_tag: bool = True
) -> int:
    """Generate docker-bake.hcl for all profiles.

    Args:
        repo_root: Path to repository root
        output_path: Path to output docker-bake.hcl file
        platforms: List of target platforms (e.g., ["linux/amd64", "linux/arm64"])
        repo: Container repository URL
        image_name: Container image name
        include_build_tag: Whether to include build-<timestamp> tag

    Returns:
        Number of profiles processed
    """
    if platforms is None:
        platforms = ["linux/amd64"]

    # Normalize platforms (ensure linux/ prefix)
    normalized_platforms = []
    for platform in platforms:
        if '/' not in platform:
            normalized_platforms.append(f'linux/{platform}')
        else:
            normalized_platforms.append(platform)

    # Get git-aware tags
    tag1, tag2 = get_version_tags(repo_root)
    git_sha = get_git_sha(repo_root, short=True)

    tags = [tag1, tag2, git_sha]

    if include_build_tag:
        build_date = datetime.utcnow().strftime('%Y%m%dT%H%M%SZ')
        tags.append(f'build-{build_date}')

    # Collect all profiles from generated/profiles
    profiles_dir = repo_root / 'generated' / 'profiles'
    if not profiles_dir.exists():
        raise FileNotFoundError(f"Profiles directory not found: {profiles_dir}")

    profiles = []
    for profile_file in sorted(profiles_dir.iterdir()):
        if profile_file.is_file() and not profile_file.name.startswith('.'):
            profiles.append(profile_file.name)

    if not profiles:
        raise ValueError(f"No profiles found in {profiles_dir}")

    # Create output directory if needed
    output_path.parent.mkdir(parents=True, exist_ok=True)

    # Write bake file
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write("# Generated docker-bake.hcl\n")
        f.write(f"# Repository: {repo}/{image_name}\n")
        f.write(f"# Platforms: {', '.join(normalized_platforms)}\n")
        f.write(f"# Tags: {', '.join(tags)}\n\n")

        emit_bake_group(f, profiles)

        for profile in profiles:
            emit_bake_target(
                f,
                profile,
                normalized_platforms,
                tags,
                repo,
                image_name
            )

    return len(profiles)


def emit_bake_group(f: TextIO, profiles: list[str]) -> None:
    """Emit group target for all profiles.

    Args:
        f: Output file handle
        profiles: List of profile names
    """
    f.write('group "all" {\n')
    f.write('  targets = [\n')
    for profile in profiles:
        f.write(f'    "final-{profile}",\n')
    f.write('  ]\n')
    f.write('}\n\n')


def emit_bake_target(
    f: TextIO,
    profile: str,
    platforms: list[str],
    tags: list[str],
    repo: str,
    image_name: str
) -> None:
    """Emit target block for a single profile.

    Args:
        f: Output file handle
        profile: Profile name
        platforms: List of target platforms
        tags: List of tags to apply
        repo: Container repository URL
        image_name: Container image name
    """
    # Compute profile slug (strip numeric prefixes like "20-00-")
    slug = compute_profile_slug(profile)

    f.write(f'target "final-{profile}" {{\n')
    f.write('  context = "."\n')
    f.write('  dockerfile = "generated/Dockerfile"\n')
    f.write(f'  target = "final-{profile}"\n')

    # Platforms
    if len(platforms) > 1:
        f.write('  platforms = [\n')
        for platform in platforms:
            f.write(f'    "{platform}",\n')
        f.write('  ]\n')
    else:
        f.write(f'  platforms = ["{platforms[0]}"]\n')

    # Tags
    f.write('  tags = [\n')
    for tag in tags:
        f.write(f'    "{repo}/{image_name}:{slug}-{tag}",\n')
    f.write('  ]\n')

    f.write('}\n\n')


def compute_profile_slug(profile: str) -> str:
    """Compute human-friendly profile slug for tagging.

    Strips numeric prefixes like "20-00-" from generated profile names.

    Examples:
        - "quarto-lecture-full" → "quarto-lecture-full"
        - "20-00-base" → "base"
        - "10-minimal" → "minimal"

    Args:
        profile: Profile name

    Returns:
        Human-friendly slug
    """
    # Strip leading numeric prefixes (pattern: digits-digits- or digits-)
    slug = re.sub(r'^(\d+-)(\d+-)?', '', profile)
    return slug if slug else profile
