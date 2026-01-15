"""Git repository utilities for version detection and tagging."""

import subprocess
from pathlib import Path


def get_git_sha(repo_root: Path, short: bool = True) -> str:
    """Get current commit SHA.

    Args:
        repo_root: Path to git repository root
        short: If True, return short SHA (7 chars), else full SHA

    Returns:
        Commit SHA or 'unknown' if not in a git repo
    """
    cmd = ['git', 'rev-parse']
    if short:
        cmd.append('--short')
    cmd.append('HEAD')

    try:
        result = subprocess.run(
            cmd,
            cwd=repo_root,
            capture_output=True,
            text=True,
            check=True
        )
        return result.stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return 'unknown'


def get_git_branch(repo_root: Path) -> str:
    """Get current branch name (normalized).

    Args:
        repo_root: Path to git repository root

    Returns:
        Branch name with '/' replaced by '-', or 'main' if not in a git repo
    """
    try:
        result = subprocess.run(
            ['git', 'rev-parse', '--abbrev-ref', 'HEAD'],
            cwd=repo_root,
            capture_output=True,
            text=True,
            check=True
        )
        branch = result.stdout.strip()
        # Normalize branch name for Docker tags (replace / with -)
        return branch.replace('/', '-')
    except (subprocess.CalledProcessError, FileNotFoundError):
        return 'main'


def get_git_tag(repo_root: Path) -> str | None:
    """Get exact tag at HEAD if exists.

    Args:
        repo_root: Path to git repository root

    Returns:
        Tag name if HEAD is tagged, None otherwise
    """
    try:
        result = subprocess.run(
            ['git', 'describe', '--tags', '--exact-match'],
            cwd=repo_root,
            capture_output=True,
            text=True,
            check=True
        )
        return result.stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None


def get_version_tags(repo_root: Path) -> tuple[str, str]:
    """Get primary and secondary tags based on git state.

    Smart tagging logic:
    - On tag: (v1.2.3, v1.2.3-abc123)
    - On main/master: (latest, main-abc123)
    - On feature branch: (branch-name, branch-name-abc123)

    Args:
        repo_root: Path to git repository root

    Returns:
        Tuple of (primary_tag, secondary_tag)
    """
    tag = get_git_tag(repo_root)
    sha = get_git_sha(repo_root, short=True)
    branch = get_git_branch(repo_root)

    if tag:
        # On a tagged commit
        return (tag, f'{tag}-{sha}')
    elif branch in ('main', 'master'):
        # On main/master branch
        return ('latest', f'{branch}-{sha}')
    else:
        # On a feature branch
        return (branch, f'{branch}-{sha}')


def is_dirty(repo_root: Path) -> bool:
    """Check if git working tree has uncommitted changes.

    Args:
        repo_root: Path to git repository root

    Returns:
        True if there are uncommitted changes, False otherwise
    """
    try:
        result = subprocess.run(
            ['git', 'status', '--porcelain'],
            cwd=repo_root,
            capture_output=True,
            text=True,
            check=True
        )
        return bool(result.stdout.strip())
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False


def get_git_remote_url(repo_root: Path) -> str | None:
    """Get remote origin URL.

    Args:
        repo_root: Path to git repository root

    Returns:
        Remote URL or None if not available
    """
    try:
        result = subprocess.run(
            ['git', 'config', '--get', 'remote.origin.url'],
            cwd=repo_root,
            capture_output=True,
            text=True,
            check=True
        )
        url = result.stdout.strip()
        # Convert SSH to HTTPS format
        if url.startswith('git@github.com:'):
            url = url.replace('git@github.com:', 'https://github.com/')
        if url.endswith('.git'):
            url = url[:-4]
        return url
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
