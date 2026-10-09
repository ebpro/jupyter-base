"""Unit tests for the bake generator's tag emission.

Covers the opt-in ``--tag-suffix`` and ``--no-build-tag`` behaviour of
``solen generate bake`` (see :func:`solen.generators.bake.generate_bake`).

The git-derived tag values are mocked so the tests are deterministic and do
not depend on the checkout's git state; a minimal ``generated/profiles`` tree
is created in a temp dir so the generator has at least one profile to emit.
"""

from pathlib import Path
from unittest.mock import patch

from solen.generators.bake import generate_bake

IMAGE_PREFIX = 'ghcr.io/ebpro/solen:'


def _make_repo_root(tmp_path: Path) -> Path:
    """Create a minimal repo_root with a single generated profile named ``20-00-base``.

    The ``20-00-`` prefix is stripped to the ``base`` slug by the generator,
    mirroring the real generated profile naming.
    """
    profiles_dir = tmp_path / 'generated' / 'profiles'
    profiles_dir.mkdir(parents=True)
    (profiles_dir / '20-00-base').write_text('feature-a\n', encoding='utf-8')
    return tmp_path


def _extract_tags(path: Path) -> list[str]:
    """Return the tag portions (text after the repo/image prefix) of every emitted tag.

    The temp repo has exactly one target (``final-base``), so every line of the
    form ``"ghcr.io/ebpro/solen:<tag>",`` belongs to that target.
    """
    tags = []
    for line in path.read_text(encoding='utf-8').splitlines():
        stripped = line.strip()
        if stripped.startswith(f'"{IMAGE_PREFIX}'):
            ref = stripped.rstrip(',').strip('"')
            tags.append(ref.split(IMAGE_PREFIX, 1)[1])
    return tags


def _run_generate(tmp_path: Path, **kwargs) -> list[str]:
    """Run generate_bake with deterministic mocked git values and return the emitted tags."""
    out = tmp_path / 'docker-bake.hcl'
    repo_root = _make_repo_root(tmp_path)
    with patch(
        'solen.generators.bake.get_version_tags',
        return_value=('develop', 'develop-94457ad'),
    ), patch('solen.generators.bake.get_git_sha', return_value='94457ad'):
        generate_bake(repo_root, out, **kwargs)
    return _extract_tags(out)


def test_default_tags_include_build_tag_and_no_suffix(tmp_path):
    """No flags: four tags, a build-<UTC> tag present, and no suffix anywhere."""
    tags = _run_generate(tmp_path)

    assert tags == [
        'base-develop',
        'base-develop-94457ad',
        'base-94457ad',
    ] + [t for t in tags if t.startswith('base-build-')]
    assert len(tags) == 4
    assert tags[0] == 'base-develop'
    assert tags[1] == 'base-develop-94457ad'
    assert tags[2] == 'base-94457ad'
    assert tags[3].startswith('base-build-')
    assert not any(t.endswith('-amd64') for t in tags)


def test_tag_suffix_appended_to_every_tag(tmp_path):
    """--tag-suffix amd64: every tag (incl. the build tag) ends in -amd64."""
    tags = _run_generate(tmp_path, tag_suffix='amd64')

    assert len(tags) == 4
    assert all(t.endswith('-amd64') for t in tags)
    assert tags[0] == 'base-develop-amd64'
    assert tags[1] == 'base-develop-94457ad-amd64'
    assert tags[2] == 'base-94457ad-amd64'
    assert tags[3].startswith('base-build-') and tags[3].endswith('-amd64')


def test_no_build_tag_omits_build_tag(tmp_path):
    """--no-build-tag: the non-deterministic build-<UTC> tag is absent (3 tags remain)."""
    tags = _run_generate(tmp_path, include_build_tag=False)

    assert tags == [
        'base-develop',
        'base-develop-94457ad',
        'base-94457ad',
    ]
    assert len(tags) == 3
    assert not any('build-' in t for t in tags)


def test_tag_suffix_and_no_build_tag(tmp_path):
    """--tag-suffix amd64 --no-build-tag: 3 suffixed tags, none build-related."""
    tags = _run_generate(tmp_path, tag_suffix='amd64', include_build_tag=False)

    assert tags == [
        'base-develop-amd64',
        'base-develop-94457ad-amd64',
        'base-94457ad-amd64',
    ]
    assert len(tags) == 3
    assert all(t.endswith('-amd64') for t in tags)
    assert not any('build-' in t for t in tags)
