"""Unit tests for the bake generator's platform declaration.

Covers the opt-in ``--platforms`` behaviour of ``solen generate bake``
(see :func:`solen.generators.bake.generate_bake`) and the invariants
enforced by :func:`solen.generators.bake.validate_platforms`:

- the default path stays host-only (backward compatibility);
- a declared platform is VISIBLE in the emitted HCL — including a
  foreign one (the whole point: the artefact carries the intent);
- multi-platform is refused when combined with ``tag_suffix`` (the
  merge-index fold sources must stay single-architecture);
- a ``tag_suffix`` that contradicts the declared platform is refused
  (a tag whose architecture disagrees with its build definition is
  exactly the mis-tagging defect class this guards).

Deterministic: no docker, no network, no build tags, git values mocked.
"""

from pathlib import Path
from unittest.mock import patch

import pytest
from click.testing import CliRunner

from solen.cli import cli
from solen.generators.bake import generate_bake, host_platform

OTHER_ARCH = 'linux/amd64' if host_platform() == 'linux/arm64' else 'linux/arm64'


def _make_repo_root(tmp_path: Path) -> Path:
    """Create a minimal repo_root with a single generated profile ``20-00-base``."""
    profiles_dir = tmp_path / 'generated' / 'profiles'
    profiles_dir.mkdir(parents=True, exist_ok=True)
    (profiles_dir / '20-00-base').write_text('feature-a\n', encoding='utf-8')
    return tmp_path


def _generate(tmp_path: Path, **kwargs) -> str:
    """Run generate_bake with mocked git values (no build tag) and return the HCL text."""
    out = tmp_path / 'docker-bake.hcl'
    repo_root = _make_repo_root(tmp_path)
    kwargs.setdefault('include_build_tag', False)
    with patch(
        'solen.generators.bake.get_version_tags',
        return_value=('develop', 'develop-94457ad'),
    ), patch('solen.generators.bake.get_git_sha', return_value='94457ad'):
        generate_bake(repo_root, out, **kwargs)
    return out.read_text(encoding='utf-8')


def _platform_lines(text: str) -> list[str]:
    """Return every emitted ``platforms = ...`` line (single-line form)."""
    return [ln.strip() for ln in text.splitlines() if ln.strip().startswith('platforms = [')]


# ---------------------------------------------------------------------------
# Default path (backward compatibility)
# ---------------------------------------------------------------------------

def test_default_emits_host_platform_only(tmp_path):
    """No platforms argument: every target pins the host platform, as before."""
    text = _generate(tmp_path)
    lines = _platform_lines(text)
    assert lines == [f'platforms = ["{host_platform()}"]'] * len(lines)
    assert len(lines) >= 1


def test_explicit_host_platform_matches_default(tmp_path):
    """Passing the host platform explicitly yields the same platform lines as the default."""
    text_default = _generate(tmp_path)
    text_explicit = _generate(tmp_path, platforms=[host_platform()])
    assert _platform_lines(text_default) == _platform_lines(text_explicit)


# ---------------------------------------------------------------------------
# Declaration reaches the artefact (incl. foreign platforms — negative test)
# ---------------------------------------------------------------------------

def test_declared_amd64_appears_in_hcl(tmp_path):
    """--platforms linux/amd64: the HCL literally carries the declaration."""
    text = _generate(tmp_path, platforms=['linux/amd64'])
    assert _platform_lines(text) == ['platforms = ["linux/amd64"]'] * len(_platform_lines(text))
    assert 'platforms = ["linux/amd64"]' in text


def test_declared_arm64_appears_in_hcl(tmp_path):
    """--platforms linux/arm64: the HCL literally carries the declaration."""
    text = _generate(tmp_path, platforms=['linux/arm64'])
    assert 'platforms = ["linux/arm64"]' in text
    assert 'platforms = ["linux/amd64"]' not in text


def test_amd64_and_arm64_declarations_differ(tmp_path):
    """The two per-arch CI declarations produce different platform lines."""
    amd = _generate(tmp_path, platforms=['linux/amd64'], tag_suffix='amd64')
    arm = _generate(tmp_path, platforms=['linux/arm64'], tag_suffix='arm64')
    assert _platform_lines(amd) == ['platforms = ["linux/amd64"]']
    assert _platform_lines(arm) == ['platforms = ["linux/arm64"]']
    assert _platform_lines(amd) != _platform_lines(arm)


def test_foreign_platform_declaration_is_visible_in_artefact(tmp_path):
    """NEGATIVE TEST (the point of the change): a platform FOREIGN to this host
    still appears verbatim in the emitted definition — it is not silently
    replaced by the host platform. A mis-routed runner therefore builds (or
    fails) against a visible, declared architecture."""
    text = _generate(tmp_path, platforms=[OTHER_ARCH])
    lines = _platform_lines(text)
    assert lines == [f'platforms = ["{OTHER_ARCH}"]']
    assert f'platforms = ["{host_platform()}"]' not in text
    assert f'# Platforms: {OTHER_ARCH}' in text


def test_bare_arch_normalized_to_linux_prefix(tmp_path):
    """A bare arch name (no os) is normalized to linux/<arch> as before."""
    text = _generate(tmp_path, platforms=['arm64'])
    assert 'platforms = ["linux/arm64"]' in text


def test_multi_platform_without_suffix_emits_list(tmp_path):
    """Multi-platform stays legal without tag_suffix (local bakes): HCL list form."""
    text = _generate(tmp_path, platforms=['linux/amd64', 'linux/arm64'])
    assert '  platforms = [\n    "linux/amd64",\n    "linux/arm64",\n  ]' in text


# ---------------------------------------------------------------------------
# Invariant enforcement (C2)
# ---------------------------------------------------------------------------

def test_multi_platform_with_tag_suffix_rejected(tmp_path):
    """A per-arch fold source must be single-architecture: refuse index nesting."""
    with pytest.raises(ValueError, match='single-architecture'):
        _generate(tmp_path, platforms=['linux/amd64', 'linux/arm64'], tag_suffix='amd64')


def test_tag_suffix_contradicting_platform_rejected(tmp_path):
    """--tag-suffix amd64 + linux/arm64 platform: tag would lie about content."""
    with pytest.raises(ValueError, match='mismatch'):
        _generate(tmp_path, platforms=['linux/arm64'], tag_suffix='amd64')
    with pytest.raises(ValueError, match='mismatch'):
        _generate(tmp_path, platforms=['linux/amd64'], tag_suffix='arm64')


def test_tag_suffix_matching_platform_accepted(tmp_path):
    """The exact CI combinations are accepted and carry the declaration."""
    amd = _generate(tmp_path, platforms=['linux/amd64'], tag_suffix='amd64')
    assert 'platforms = ["linux/amd64"]' in amd
    arm = _generate(tmp_path, platforms=['linux/arm64'], tag_suffix='arm64')
    assert 'platforms = ["linux/arm64"]' in arm


def test_host_default_never_rejected_by_suffix_rule(tmp_path):
    """Backward compatibility (C1): an UNDECLARED host platform combined with
    a foreign tag_suffix must NOT error — that combination was legal before
    this feature (e.g. `--tag-suffix amd64` on an ARM dev box). Only explicit
    declarations are checked for contradiction; the fold-time assertion in
    merge-index remains the backstop for undeclared builds."""
    host_arch = host_platform().rsplit('/', 1)[-1]
    foreign_suffix = 'amd64' if host_arch == 'arm64' else 'arm64'
    text = _generate(tmp_path, tag_suffix=foreign_suffix)
    assert f'platforms = ["{host_platform()}"]' in text


def test_non_fold_tag_suffix_allows_any_single_platform(tmp_path):
    """A tag_suffix outside the fold architectures (e.g. a local marker) is
    not checked against the platform arch — only the fold sources are."""
    text = _generate(tmp_path, platforms=['linux/arm64'], tag_suffix='debug')
    assert 'platforms = ["linux/arm64"]' in text


@pytest.mark.parametrize('bad', [
    '',                    # empty entry
    'windows/amd64',       # foreign OS
    'darwin/arm64',        # foreign OS
    'amd64/docker',        # inverted
    'linux/unknownarch',   # unknown architecture
    'bogus',               # normalized to linux/bogus -> unknown arch
])
def test_invalid_platform_rejected(tmp_path, bad):
    with pytest.raises(ValueError, match='Invalid platform|empty'):
        _generate(tmp_path, platforms=[bad])


def test_empty_platforms_list_rejected(tmp_path):
    """An explicitly empty list is a caller error, not a silent host fallback."""
    with pytest.raises(ValueError, match='empty'):
        _generate(tmp_path, platforms=[])


# ---------------------------------------------------------------------------
# CLI wiring (argparse -> artefact)
# ---------------------------------------------------------------------------

def _invoke_bake(tmp_path: Path, args: list[str]):
    runner = CliRunner()
    with patch(
        'solen.generators.bake.get_version_tags',
        return_value=('develop', 'develop-94457ad'),
    ), patch('solen.generators.bake.get_git_sha', return_value='94457ad'):
        return runner.invoke(
            cli,
            ['--repo-root', str(tmp_path), 'generate', 'bake',
             '--output', 'bake.hcl', '--no-build-tag', *args],
        )


def test_cli_platforms_flag_reaches_artefact(tmp_path):
    _make_repo_root(tmp_path)
    result = _invoke_bake(tmp_path, ['--platforms', 'linux/arm64'])
    assert result.exit_code == 0, result.output
    assert 'platforms = ["linux/arm64"]' in (tmp_path / 'bake.hcl').read_text()


def test_cli_repeatable_and_comma_separated_platforms(tmp_path):
    _make_repo_root(tmp_path)
    result = _invoke_bake(
        tmp_path, ['--platforms', 'linux/amd64,linux/arm64'])
    assert result.exit_code == 0, result.output
    text = (tmp_path / 'bake.hcl').read_text()
    assert '"linux/amd64",' in text and '"linux/arm64",' in text


def test_cli_default_omits_platforms(tmp_path):
    _make_repo_root(tmp_path)
    result = _invoke_bake(tmp_path, [])
    assert result.exit_code == 0, result.output
    assert f'platforms = ["{host_platform()}"]' in (tmp_path / 'bake.hcl').read_text()


def test_cli_rejects_contradictory_declaration(tmp_path):
    _make_repo_root(tmp_path)
    result = _invoke_bake(
        tmp_path, ['--tag-suffix', 'amd64', '--platforms', 'linux/arm64'])
    assert result.exit_code == 1
    assert 'mismatch' in result.output


def test_cli_rejects_multi_platform_fold_source(tmp_path):
    _make_repo_root(tmp_path)
    result = _invoke_bake(
        tmp_path,
        ['--tag-suffix', 'amd64', '--platforms', 'linux/amd64,linux/arm64'])
    assert result.exit_code == 1
    assert 'single-architecture' in result.output


def test_cli_empty_platforms_value_is_usage_error(tmp_path):
    _make_repo_root(tmp_path)
    result = _invoke_bake(tmp_path, ['--platforms', ''])
    assert result.exit_code != 0
    assert 'empty' in result.output
