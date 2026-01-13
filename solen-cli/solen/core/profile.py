"""Profile parsing and expansion."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass
class ProfileData:
    """Parsed profile data."""
    features: list[str]
    options: dict[str, str]
    services: list[str]


def parse_profile(profile_path: Path, profiles_dir: Path, visited: set[str] | None = None) -> ProfileData:
    """Parse a profile file and expand parent references.
    
    Args:
        profile_path: Path to profile file
        profiles_dir: Directory containing profiles
        visited: Set of already visited profiles (for cycle detection)
        
    Returns:
        ProfileData with accumulated features, options, and services
    """
    if visited is None:
        visited = set()
    
    profile_name = profile_path.name
    if profile_name in visited:
        raise ValueError(f"Circular profile dependency detected: {profile_name}")
    
    visited.add(profile_name)
    
    # Initialize with empty data
    features: list[str] = []
    options: dict[str, str] = {}
    services: list[str] = []
    
    with open(profile_path, encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            
            # Skip empty lines and comments
            if not line or line.startswith('#'):
                continue
            
            # Handle directives
            if line.startswith('@parent:') or line.startswith('@profile:'):
                parent_name = line.split(':', 1)[1].strip()
                
                # Find parent profile (check multiple locations)
                parent_path = None
                for check_dir in [profiles_dir, profiles_dir.parent / 'generated' / 'profiles']:
                    candidate = check_dir / parent_name
                    if candidate.exists():
                        parent_path = candidate
                        break
                
                if not parent_path:
                    raise FileNotFoundError(f"Parent profile not found: {parent_name}")
                
                # Recursively parse parent
                parent_data = parse_profile(parent_path, profiles_dir, visited)
                
                # Inherit from parent (parent's data comes first)
                features = parent_data.features + features
                options = {**parent_data.options, **options}  # Child options override parent
                services = parent_data.services + services
            
            elif line.startswith('@options:'):
                # Parse key=value;key2=value2 format
                opts_str = line.split(':', 1)[1].strip()
                for pair in opts_str.split(';'):
                    pair = pair.strip()
                    if '=' in pair:
                        key, value = pair.split('=', 1)
                        options[key.strip()] = value.strip()
            
            elif line.startswith('@services:'):
                # Service declaration (for devcontainer)
                service = line.split(':', 1)[1].strip()
                if service:
                    services.append(service)
            
            elif line.startswith('@'):
                # Skip unknown directives
                continue
            
            else:
                # Regular feature line
                features.append(line)
    
    return ProfileData(features=features, options=options, services=services)


def find_profile(profile_name: str, repo_root: Path) -> Path:
    """Find a profile file by name.
    
    Searches in:
    - profiles/
    - generated/profiles/
    
    Args:
        profile_name: Name of the profile
        repo_root: Repository root directory
        
    Returns:
        Path to profile file
        
    Raises:
        FileNotFoundError: If profile not found
    """
    search_paths = [
        repo_root / 'profiles' / profile_name,
        repo_root / 'generated' / 'profiles' / profile_name,
    ]
    
    for path in search_paths:
        if path.exists():
            return path
    
    raise FileNotFoundError(
        f"Profile not found: {profile_name}\n"
        f"Searched: {', '.join(str(p) for p in search_paths)}"
    )
