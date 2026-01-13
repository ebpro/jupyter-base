"""Dockerfile generator for profiles."""

from __future__ import annotations

from pathlib import Path
from typing import TextIO

from solen.core.feature import (
    collect_feature_metadata,
    collect_feature_options,
    expand_feature_dependencies,
    topological_sort_features,
)
from solen.core.profile import find_profile, parse_profile


def docker_escape(value: str) -> str:
    """Escape string for use in Dockerfile."""
    return value.replace('\\', '\\\\').replace('"', '\\"')


def emit_dockerfile_header(f: TextIO, repo_root: Path) -> None:
    """Emit Dockerfile header with base image and setup."""
    f.write("# Generated Dockerfile\n")
    f.write('ARG VARIANT="ubuntu-24.04"\n')
    f.write('FROM mcr.microsoft.com/devcontainers/base:${VARIANT} AS base\n')
    f.write('LABEL org.solen.vendor="Solen"\n')
    f.write('ARG NB_USER=jovyan\n')
    f.write('ARG NB_UID=1001\n')
    f.write('ARG NB_GID=1001\n')
    f.write('ENV HOME=/home/jovyan\n')
    f.write('WORKDIR /home/jovyan\n\n')
    
    # Copy helper scripts and inputs
    f.write('COPY scripts/lib/helpers.sh /opt/solen/_lib/helpers.sh\n')
    f.write('COPY inputs /opt/solen/inputs\n')
    f.write('COPY artefacts /opt/solen/artefacts\n')
    f.write('ENV FEATURE_HELPERS_DIR=/opt/solen/_lib ')
    f.write('INPUTS_DIR=/opt/solen/inputs ')
    f.write('ARTEFACTS_DIR=/opt/solen/artefacts\n')
    f.write('RUN mkdir -p /opt/.features /scripts/lib && \\\n')
    f.write('    printf "source /opt/solen/_lib/helpers.sh || true" > /scripts/lib/features.sh\n\n')
    
    # Copy prebaked toolcache if it exists
    toolcache_dir = repo_root / 'generated' / 'toolcache'
    if toolcache_dir.exists():
        f.write('# Inject prebaked toolcache from repository\n')
        f.write('COPY generated/toolcache /opt/toolcache\n')
        f.write('RUN chmod -R a+rX /opt/toolcache || true\n\n')


def emit_feature_installation(f: TextIO, features: list[str]) -> None:
    """Emit RUN instruction to install features with BuildKit caching."""
    if not features:
        return
    
    f.write('RUN \\\n')
    
    # Per-feature bind mounts (read-only)
    for feat in features:
        f.write(f'  --mount=type=bind,source=features/{feat},target=/tmp/features/{feat},readonly \\\n')
    
    # Shared bind mounts (read-only)
    f.write('  --mount=type=bind,source=inputs,target=/tmp/inputs,readonly \\\n')
    f.write('  --mount=type=bind,source=artefacts,target=/tmp/artefacts,readonly \\\n')
    f.write('  --mount=type=bind,source=scripts,target=/tmp/scripts,readonly \\\n')
    
    # BuildKit cache mounts for performance
    f.write('  --mount=type=cache,target=/var/cache/apt,sharing=locked \\\n')
    f.write('  --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \\\n')
    f.write('  --mount=type=cache,target=/opt/toolcache,sharing=locked \\\n')
    f.write('  --mount=type=cache,target=/root/.cache,sharing=locked \\\n')
    f.write('  --mount=type=cache,target=/home/jovyan/.cache,sharing=locked,uid=1001,gid=1001 \\\n')
    
    # Build quoted array for bash
    quoted_feats = [f'"{feat}"' for feat in features]
    feats_array = ' '.join(quoted_feats)
    
    f.write(f"  bash -eux -o pipefail -c 'feats=({feats_array}); \\\n")
    f.write('for f in \"${feats[@]}\"; do \\\n')
    f.write('    if [ -d \"/tmp/features/$f\" ]; then \\\n')
    f.write('      chmod +x /tmp/features/$f/install.sh 2>/dev/null || true; \\\n')
    f.write('      [ -f /tmp/features/$f/install.sh ] && { set +u; bash -c \"source /opt/solen/_lib/helpers.sh 2>/dev/null || true; source /tmp/features/$f/install.sh\"; set -u; }; \\\n')
    f.write('    fi; \\\n')
    f.write("  done; apt-get clean; rm -rf /var/lib/apt/lists/auxfiles /var/lib/apt/lists/lock /var/lib/apt/lists/partial'\n\n")


def generate_single_profile_dockerfile(
    repo_root: Path,
    profile_name: str,
    output_path: Path
) -> None:
    """Generate Dockerfile for a single profile.
    
    Args:
        repo_root: Repository root directory
        profile_name: Name of the profile
        output_path: Path to output Dockerfile
    """
    # Find and parse profile
    profile_path = find_profile(profile_name, repo_root)
    profiles_dir = repo_root / 'profiles'
    profile_data = parse_profile(profile_path, profiles_dir)
    
    # Expand and sort features
    features_dir = repo_root / 'features'
    expanded_features = expand_feature_dependencies(features_dir, profile_data.features)
    sorted_features = topological_sort_features(features_dir, expanded_features)
    
    # Collect metadata
    metadata = collect_feature_metadata(features_dir, sorted_features)
    feature_options = collect_feature_options(features_dir, sorted_features)
    
    # Merge profile options with feature defaults (profile wins)
    all_options = {**feature_options, **profile_data.options}
    
    # Generate Dockerfile
    output_path.parent.mkdir(parents=True, exist_ok=True)
    
    with open(output_path, 'w', encoding='utf-8') as f:
        # Header
        emit_dockerfile_header(f, repo_root)
        
        # Profile stage
        f.write(f'\n# --- Profile: {profile_name} ---\n')
        f.write('FROM base AS profile\n')
        
        # Labels
        provides_str = ','.join(metadata['provides'])
        features_str = ' '.join(sorted_features) if sorted_features else 'none'
        f.write(f'LABEL org.solen.profile="{profile_name}" \\\n')
        f.write(f'      org.solen.features.added="{features_str}" \\\n')
        f.write(f'      org.solen.features.provides="{provides_str}"\n\n')
        
        # Environment variables from profile options
        for key, value in profile_data.options.items():
            f.write(f'ENV {key}="{docker_escape(value)}"\n')
        
        # Environment variables from feature defaults (not already set by profile)
        for key, value in all_options.items():
            if key not in profile_data.options:
                f.write(f'ENV {key}="{docker_escape(value)}"\n')
        
        if profile_data.options or all_options:
            f.write('\n')
        
        # Install features
        emit_feature_installation(f, sorted_features)
        
        # Final stage
        f.write('FROM profile AS final\n')


def generate_multi_profile_dockerfile(repo_root: Path, output_path: Path) -> list[str]:
    """Generate Dockerfile with all profiles as stages.
    
    Args:
        repo_root: Repository root directory
        output_path: Path to output Dockerfile
        
    Returns:
        List of generated profile names
    """
    from solen.generators.profiles import generate_profiles
    
    # Expand all matrix files to generate profiles
    matrix_dir = repo_root / 'profiles' / 'matrix'
    generated_dir = repo_root / 'generated' / 'profiles'
    
    # Clean and regenerate all profiles
    if generated_dir.exists():
        import shutil
        shutil.rmtree(generated_dir)
    generated_dir.mkdir(parents=True, exist_ok=True)
    
    # Expand matrix files
    if matrix_dir.exists():
        for matrix_file in matrix_dir.glob('*.yaml'):
            generate_profiles(matrix_file, generated_dir, prefix='')
        for matrix_file in matrix_dir.glob('*.yml'):
            generate_profiles(matrix_file, generated_dir, prefix='')
    
    # Also check for top-level matrix.yaml
    top_matrix = repo_root / 'profiles' / 'matrix.yaml'
    if top_matrix.exists():
        generate_profiles(top_matrix, generated_dir, prefix='')
    
    # Collect all profiles (from repo and generated)
    profiles_dir = repo_root / 'profiles'
    profile_names: list[str] = []
    
    # From repo
    if profiles_dir.exists():
        for p in profiles_dir.iterdir():
            if p.is_file() and p.name not in ('README.md', 'base'):
                profile_names.append(p.name)
    
    # From generated
    if generated_dir.exists():
        for p in generated_dir.iterdir():
            if p.is_file() and p.name not in ('README.md', 'base'):
                profile_names.append(p.name)
    
    # Remove duplicates and sort
    profile_names = sorted(set(profile_names))
    
    # Generate Dockerfile
    output_path.parent.mkdir(parents=True, exist_ok=True)
    
    with open(output_path, 'w', encoding='utf-8') as f:
        # Header (once)
        emit_dockerfile_header(f, repo_root)
        
        # Process each profile
        features_dir = repo_root / 'features'
        
        for profile_name in profile_names:
            try:
                # Find and parse profile
                profile_path = find_profile(profile_name, repo_root)
                profile_data = parse_profile(profile_path, profiles_dir)
                
                # Expand and sort features
                expanded_features = expand_feature_dependencies(features_dir, profile_data.features)
                sorted_features = topological_sort_features(features_dir, expanded_features)
                
                # Collect metadata
                metadata = collect_feature_metadata(features_dir, sorted_features)
                feature_options = collect_feature_options(features_dir, sorted_features)
                
                # Merge options
                all_options = {**feature_options, **profile_data.options}
                
                # Profile stage
                f.write(f'\n# --- Profile: {profile_name} ---\n')
                f.write(f'FROM base AS profile-{profile_name}\n')
                
                # Labels
                provides_str = ','.join(metadata['provides'])
                features_str = ' '.join(sorted_features) if sorted_features else 'none'
                f.write(f'LABEL org.solen.profile="{profile_name}" \\\n')
                f.write(f'      org.solen.features.added="{features_str}" \\\n')
                f.write(f'      org.solen.features.provides="{provides_str}"\n\n')
                
                # Environment variables
                for key, value in profile_data.options.items():
                    f.write(f'ENV {key}="{docker_escape(value)}"\n')
                
                for key, value in all_options.items():
                    if key not in profile_data.options:
                        f.write(f'ENV {key}="{docker_escape(value)}"\n')
                
                if profile_data.options or all_options:
                    f.write('\n')
                
                # Install features
                emit_feature_installation(f, sorted_features)
                
                # Final stage for this profile
                f.write(f'FROM profile-{profile_name} AS final-{profile_name}\n')
                
            except Exception as e:
                # Log error but continue with other profiles
                print(f"Warning: Failed to process profile {profile_name}: {e}")
                continue
    
    return profile_names
