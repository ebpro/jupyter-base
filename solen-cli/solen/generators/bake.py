"""Docker Bake file generator."""

import platform
import re
from datetime import datetime
from pathlib import Path
from typing import TextIO

from solen.core.profile import is_profile_file
from solen.utils.git import get_git_sha, get_version_tags


def host_platform() -> str:
    """Return the linux platform identifier for the current host arch."""
    machine = platform.machine().lower()
    return "linux/arm64" if machine in ("arm64", "aarch64") else "linux/amd64"


# Architectures for which ci-publish.yml's merge-index job folds the
# per-arch tag "${T}-<arch>" as a SINGLE-architecture source image. A
# --tag-suffix value in this set is an architecture declaration, so the
# emitted build definition must declare the same architecture.
FOLD_ARCH_SUFFIXES = ("amd64", "arm64")

# Linux architectures Docker/BuildKit recognise (os/arch, with the
# optional /variant suffix stripped before the check).
VALID_LINUX_ARCHES = frozenset(
    {"386", "amd64", "arm", "arm64", "mips64le", "ppc64le", "riscv64", "s390x"}
)


def validate_platforms(
    platforms: list[str], tag_suffix: str | None, explicit: bool = True
) -> None:
    """Validate a normalized platform list against its emission context.

    Enforces the invariants that make a declared target architecture
    trustworthy in the published artefact:

    1. Every platform must be ``linux/<arch>`` (optionally with a
       ``/variant`` suffix, e.g. ``linux/arm/v7``). These images are
       linux-only; a typo or foreign OS fails loudly at generation
       instead of producing an unservable manifest entry.
    2. A multi-platform list cannot be combined with ``tag_suffix``.
       The suffix marks a per-arch publish tag that merge-index folds
       as a single-architecture source (``imagetools create`` input);
       pushing an index there would nest indexes and corrupt the fold.
       Multi-platform remains legal without the suffix (local bakes).
    3. When the platforms were EXPLICITLY declared (``explicit=True``)
       and the suffix names a fold architecture (amd64/arm64), the
       single declared platform must name the same architecture. A
       mismatch (e.g. ``--tag-suffix amd64 --platforms linux/arm64``)
       would emit an artefact whose content disagrees with its tag —
       the exact class of defect behind the mis-tagged publish
       incident — so it is refused before anything is written.
       The host-derived DEFAULT is exempt from this rule: no
       architecture was declared, so there is no contradiction to
       catch, and rejecting it would change the pre-existing default
       path (e.g. ``--tag-suffix amd64`` on an ARM dev box), breaking
       backward compatibility. The fold-time assertion in merge-index
       remains the backstop for undeclared builds.

    Args:
        platforms: Normalized (``linux/``-prefixed) platforms to emit.
        tag_suffix: The per-arch tag marker passed to the generator, or None.
        explicit: Whether the caller declared the platforms itself (True)
            or they come from :func:`host_platform` (False).

    Raises:
        ValueError: On any invalid platform string or broken invariant.
    """
    if not platforms:
        raise ValueError(
            "platforms list is empty; omit the argument to use the host platform"
        )

    if explicit:
        for plat in platforms:
            os_name, _, arch = plat.partition('/')
            if os_name != 'linux' or arch.split('/')[0] not in VALID_LINUX_ARCHES:
                raise ValueError(
                    f"Invalid platform {plat!r}: expected 'linux/<arch>' with arch in "
                    f"{', '.join(sorted(VALID_LINUX_ARCHES))} (e.g. 'linux/amd64', "
                    f"'linux/arm64')."
                )

    if len(platforms) > 1 and tag_suffix:
        raise ValueError(
            f"Multi-platform bake ({', '.join(platforms)}) cannot be combined with "
            f"tag_suffix {tag_suffix!r}: a suffixed tag is folded by merge-index as "
            "a single-architecture source image; emitting an index there would nest "
            "indexes. Pass exactly one platform, or omit --tag-suffix."
        )

    if explicit and len(platforms) == 1 and tag_suffix in FOLD_ARCH_SUFFIXES:
        declared_arch = platforms[0].rsplit('/', 1)[-1]
        if declared_arch != tag_suffix:
            raise ValueError(
                f"Platform/tag-suffix mismatch: tag_suffix {tag_suffix!r} declares "
                f"{tag_suffix} content, but the build platform is {platforms[0]!r}. "
                "Refusing to emit tags whose architecture disagrees with their "
                "build definition."
            )


def generate_bake(
    repo_root: Path,
    output_path: Path,
    platforms: list[str] | None = None,
    repo: str = "ghcr.io/ebpro",
    image_name: str = "solen",
    include_build_tag: bool = True,
    tag_suffix: str | None = None,
    harbor_cache: str | None = None,
    no_cache_to: bool = False
) -> int:
    """Generate docker-bake.hcl for all profiles.

    Args:
        repo_root: Path to repository root
        output_path: Path to output docker-bake.hcl file
        platforms: List of target platforms (e.g., ["linux/amd64", "linux/arm64"]).
            When None, defaults to the host platform only (``[host_platform()]``),
            preserving the historical behaviour. Declare the target explicitly in
            CI so the emitted definition carries the intended architecture
            instead of inheriting it from whichever runner claims the job
            (see :func:`validate_platforms` for the invariants enforced on the
            combination of platforms and ``tag_suffix``).
        repo: Container repository URL
        image_name: Container image name
        include_build_tag: Whether to include build-<timestamp> tag
        tag_suffix: Optional per-arch marker appended as "-<suffix>" to every emitted tag
        harbor_cache: Optional base ref of the Harbor build-cache registry
            (e.g. "harbor.ebruno.fr/solen/build-cache"). When set, each target
            emits a per-profile/per-arch ``cache-from`` registry cache entry,
            plus a ``cache-to`` entry unless ``no_cache_to`` is True.
        no_cache_to: When ``harbor_cache`` is set, omit the ``cache-to`` export
            attribute. The cache upload is best-effort: Harbor answers 499
            (Client Closed Request) on large layer uploads (e.g. quarto-containers),
            which must not fail the build. ``cache-from`` (reading the Harbor
            cache) is always kept.

    Returns:
        Number of profiles processed
    """
    if platforms is None:
        platforms = [host_platform()]
        explicit = False
    else:
        explicit = True

    # Normalize platforms (ensure linux/ prefix)
    normalized_platforms = []
    for plat in platforms:
        if '/' not in plat:
            normalized_platforms.append(f'linux/{plat}')
        else:
            normalized_platforms.append(plat)

    validate_platforms(normalized_platforms, tag_suffix, explicit=explicit)

    # Get git-aware tags
    tag1, tag2 = get_version_tags(repo_root)
    git_sha = get_git_sha(repo_root, short=True)

    tags = [tag1, tag2, git_sha]

    if include_build_tag:
        build_date = datetime.utcnow().strftime('%Y%m%dT%H%M%SZ')
        tags.append(f'build-{build_date}')

    if tag_suffix:
        tags = [f'{tag}-{tag_suffix}' for tag in tags]

    # Per-arch marker for the Harbor cache ref. tag_suffix is the arch in CI
    # (e.g. "amd64"/"arm64"); fall back to the host arch for local use.
    cache_arch = tag_suffix or host_platform().rsplit('/', 1)[-1]

    # Collect all profiles from generated/profiles
    profiles_dir = repo_root / 'generated' / 'profiles'
    if not profiles_dir.exists():
        raise FileNotFoundError(f"Profiles directory not found: {profiles_dir}")

    profiles = [
        profile_file.name
        for profile_file in sorted(profiles_dir.iterdir())
        if is_profile_file(profile_file)
    ]

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
                image_name,
                harbor_cache,
                no_cache_to,
                cache_arch
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
    image_name: str,
    harbor_cache: str | None = None,
    no_cache_to: bool = False,
    cache_arch: str | None = None
) -> None:
    """Emit target block for a single profile.

    Args:
        f: Output file handle
        profile: Profile name
        platforms: List of target platforms
        tags: List of tags to apply
        repo: Container repository URL
        image_name: Container image name
        harbor_cache: Optional Harbor build-cache base ref (see generate_bake)
        no_cache_to: Omit the cache-to export when harbor_cache is set
        cache_arch: Arch marker for the per-target Harbor cache ref
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

    # Harbor registry build cache (opt-in via harbor_cache). The ref uses the
    # raw profile name + arch, matching the refs the CI build jobs used to pass
    # via buildx --set, so existing Harbor cache entries stay reusable.
    # cache-from (reading the cache) is always kept; cache-to (the upload) is
    # best-effort and omitted when no_cache_to is set, because Harbor answers
    # 499 on large layer uploads (e.g. quarto-containers).
    if harbor_cache:
        arch = cache_arch or 'amd64'
        cache_entry = f'type=registry,ref={harbor_cache}:{profile}-{arch},mode=max'
        f.write(f'  cache-from = ["{cache_entry}"]\n')
        if not no_cache_to:
            f.write(f'  cache-to = ["{cache_entry}"]\n')

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
