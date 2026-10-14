"""Unit tests for the bake generator's Harbor registry cache emission.

Covers the opt-in ``--harbor-cache`` and ``--no-cache-to`` behaviour of
``solen generate bake`` (see :func:`solen.generators.bake.generate_bake`).

The git-derived tag values are mocked so the tests are deterministic and do
not depend on the checkout's git state; a minimal ``generated/profiles`` tree
is created in a temp dir so the generator has at least one profile to emit.
"""

from pathlib import Path
from unittest.mock import patch

from solen.generators.bake import generate_bake

HARBOR_CACHE = 'harbor.ebruno.fr/solen/build-cache'
PROFILE = '20-00-base'  # raw profile name, as found in generated/profiles


def _make_repo_root(tmp_path: Path) -> Path:
    """Create a minimal repo_root with a single generated profile."""
    profiles_dir = tmp_path / 'generated' / 'profiles'
    profiles_dir.mkdir(parents=True)
    (profiles_dir / PROFILE).write_text('feature-a\n', encoding='utf-8')
    return tmp_path


def _run_generate(tmp_path: Path, **kwargs) -> str:
    """Run generate_bake with deterministic mocked git values and return the HCL text."""
    out = tmp_path / 'docker-bake.hcl'
    repo_root = _make_repo_root(tmp_path)
    with patch(
        'solen.generators.bake.get_version_tags',
        return_value=('develop', 'develop-94457ad'),
    ), patch('solen.generators.bake.get_git_sha', return_value='94457ad'):
        generate_bake(repo_root, out, **kwargs)
    return out.read_text(encoding='utf-8')


def test_default_hcl_has_no_cache_attributes(tmp_path):
    """No --harbor-cache: the HCL is unchanged (no cache-from / cache-to)."""
    hcl = _run_generate(tmp_path)

    assert 'cache-from' not in hcl
    assert 'cache-to' not in hcl


def test_harbor_cache_emits_cache_from_and_cache_to(tmp_path):
    """--harbor-cache: each target gets cache-from and cache-to (per profile+arch).

    The ref uses the raw profile name + arch, matching the refs the CI build
    jobs used to pass via buildx --set, so existing Harbor cache entries stay
    reusable.
    """
    hcl = _run_generate(tmp_path, harbor_cache=HARBOR_CACHE,
                        tag_suffix='amd64', include_build_tag=False)

    entry = f'type=registry,ref={HARBOR_CACHE}:{PROFILE}-amd64,mode=max'
    assert f'cache-from = ["{entry}"]' in hcl
    assert f'cache-to = ["{entry}"]' in hcl


def test_no_cache_to_omits_cache_to_keeps_cache_from(tmp_path):
    """--harbor-cache --no-cache-to: cache-from kept, cache-to omitted.

    This is the retry path of ci-publish.yml: Harbor answers 499 on the
    cache-to upload of large layers, so the retry must keep reading the
    Harbor cache (cache-from) without exporting it (cache-to).
    """
    hcl = _run_generate(tmp_path, harbor_cache=HARBOR_CACHE,
                        tag_suffix='arm64', include_build_tag=False,
                        no_cache_to=True)

    entry = f'type=registry,ref={HARBOR_CACHE}:{PROFILE}-arm64,mode=max'
    assert f'cache-from = ["{entry}"]' in hcl
    assert 'cache-to' not in hcl


def test_no_cache_to_alone_is_a_noop(tmp_path):
    """--no-cache-to without --harbor-cache: no cache attributes at all."""
    hcl = _run_generate(tmp_path, no_cache_to=True)

    assert 'cache-from' not in hcl
    assert 'cache-to' not in hcl


# ---------------------------------------------------------------------------
# --no-cache: the cache-registry-outage primitive.
#
# Motivation (incident, run 38436645327): when Harbor is unreachable or its
# robot token is rejected, BuildKit fails at *importer* setup
# ("failed to configure registry cache importer: ... 401 Unauthorized") and
# again on cache-to blobs. --no-cache-to cannot recover that case because it
# deliberately keeps cache-from, so the bake still references the dead
# registry as an import source. --no-cache omits both directives, degrading
# the build to a cold one instead of a hard failure.
# ---------------------------------------------------------------------------


def test_no_cache_omits_both_directives(tmp_path):
    """--harbor-cache --no-cache: neither cache-from nor cache-to is emitted."""
    hcl = _run_generate(tmp_path, harbor_cache=HARBOR_CACHE,
                        tag_suffix='amd64', include_build_tag=False,
                        no_cache=True)

    assert 'cache-from' not in hcl
    assert 'cache-to' not in hcl
    # The rest of the target must still be a valid, complete definition.
    assert HARBOR_CACHE not in hcl
    assert 'target = "final-20-00-base"' in hcl
    assert 'tags = [' in hcl


def test_no_cache_suppresses_cache_to_even_with_no_cache_to_false(tmp_path):
    """--no-cache dominates: the flag pair must never emit a partial cache ref."""
    hcl = _run_generate(tmp_path, harbor_cache=HARBOR_CACHE,
                        tag_suffix='arm64', include_build_tag=False,
                        no_cache=True, no_cache_to=False)

    assert 'cache-from' not in hcl
    assert 'cache-to' not in hcl


def test_no_cache_alone_is_a_noop(tmp_path):
    """--no-cache without --harbor-cache: nothing changes (no cache attributes)."""
    hcl = _run_generate(tmp_path, no_cache=True)

    assert 'cache-from' not in hcl
    assert 'cache-to' not in hcl


def test_no_cache_and_no_cache_to_are_not_interchangeable(tmp_path):
    """Regression guard: --no-cache-to must KEEP cache-from.

    The two flags cover different failure modes and must never be conflated:
    the 499-on-large-layer retry relies on still reading the Harbor cache,
    while the outage path must stop referencing it entirely. Generated from
    the same arguments, the two outputs differ only by cache-from.
    """
    common = dict(harbor_cache=HARBOR_CACHE, tag_suffix='amd64',
                  include_build_tag=False)
    entry = f'type=registry,ref={HARBOR_CACHE}:{PROFILE}-amd64,mode=max'

    retry = _run_generate(tmp_path / 'retry', **common, no_cache_to=True)
    nocache = _run_generate(tmp_path / 'nocache', **common, no_cache=True)

    # --no-cache-to: import source survives, export is dropped.
    assert f'cache-from = ["{entry}"]' in retry
    assert 'cache-to' not in retry
    # --no-cache: both gone.
    assert 'cache-from' not in nocache
    assert 'cache-to' not in nocache
    # The outage bake is strictly a subset of the retry bake.
    assert retry != nocache


def test_no_cache_default_is_byte_identical_to_omitting_it(tmp_path):
    """no_cache defaults to False: existing output must not change at all."""
    common = dict(harbor_cache=HARBOR_CACHE, tag_suffix='amd64',
                  include_build_tag=False)

    implicit = _run_generate(tmp_path / 'implicit', **common)
    explicit = _run_generate(tmp_path / 'explicit', no_cache=False, **common)
    plain = _run_generate(tmp_path / 'plain')
    plain_with_flag_false = _run_generate(tmp_path / 'plainf', no_cache=False)

    assert implicit == explicit
    assert plain == plain_with_flag_false
