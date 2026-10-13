"""Alignment tests for the shared profile-set predicate.

The bake generator (:mod:`solen.generators.bake`) and the Dockerfile generator
(:mod:`solen.generators.dockerfile_gen`) MUST derive the *same* set of profiles
from a directory listing. Historically bake skipped only dotfiles while the
Dockerfile generator skipped ``{README.md, base, .gitkeep}`` -- so a stray
``base`` or ``README.md`` in ``generated/profiles`` made bake emit a
``final-<name>`` target whose Dockerfile stage was never built: a dangling bake
target that only fails at build time, in CI, far from the cause.

Both generators now consume the single :func:`solen.core.profile.is_profile_file`
predicate. These tests pin that source of truth and the resulting behaviour.
"""

from pathlib import Path
from unittest.mock import patch

from solen.core.profile import NON_PROFILE_NAMES, is_profile_file
from solen.generators import bake as bake_mod
from solen.generators import dockerfile_gen as dockerfile_mod
from solen.generators.bake import generate_bake


def _make_profile(name: str, directory: Path) -> Path:
    """Write a minimal profile file called ``name`` into ``directory``."""
    path = directory / name
    path.write_text("feature-a\n", encoding="utf-8")
    return path


# --- predicate unit behaviour -------------------------------------------------


def test_predicate_accepts_plain_profile(tmp_path):
    """A regular, non-hidden, non-reserved file is a profile."""
    profile = _make_profile("quarto-full", tmp_path)
    assert is_profile_file(profile) is True


def test_predicate_rejects_hidden_entries(tmp_path):
    """Dotfiles (e.g. .gitkeep) are not profiles."""
    hidden = tmp_path / ".gitkeep"
    hidden.write_text("", encoding="utf-8")
    assert is_profile_file(hidden) is False


def test_predicate_rejects_reserved_names(tmp_path):
    """README.md and base are placeholders, not profiles."""
    for reserved in NON_PROFILE_NAMES:
        path = _make_profile(reserved, tmp_path)
        assert is_profile_file(path) is False


def test_predicate_rejects_directories(tmp_path):
    """A directory named like a profile is not a profile."""
    (tmp_path / "matrix").mkdir()
    assert is_profile_file(tmp_path / "matrix") is False


# --- single source of truth ---------------------------------------------------


def test_both_generators_share_the_same_predicate_object():
    """Bake and Dockerfile must reference the *identical* predicate.

    Object identity (not just equal behaviour) is the guarantee: if either
    generator later re-introduces its own inline filter, this test fails and
    the two profile sets can silently diverge again.
    """
    assert bake_mod.is_profile_file is is_profile_file
    assert dockerfile_mod.is_profile_file is is_profile_file


# --- bake behaviour (the bug class, not just the symptom) ---------------------


def _run_bake(tmp_path: Path) -> tuple[int, str]:
    """Populate generated/profiles with real + stray files, run bake, return (count, hcl)."""
    profiles_dir = tmp_path / "generated" / "profiles"
    profiles_dir.mkdir(parents=True)
    _make_profile("dev", profiles_dir)
    _make_profile("quarto-full", profiles_dir)
    # Stray non-profile files that used to leak into bake.
    _make_profile("README.md", profiles_dir)
    _make_profile("base", profiles_dir)
    (profiles_dir / ".gitkeep").write_text("", encoding="utf-8")
    (profiles_dir / "subdir").mkdir()  # a directory, must be ignored too

    out = tmp_path / "docker-bake.hcl"
    with patch(
        "solen.generators.bake.get_version_tags",
        return_value=("develop", "develop-94457ad"),
    ), patch("solen.generators.bake.get_git_sha", return_value="94457ad"):
        count = generate_bake(tmp_path, out)
    return count, out.read_text(encoding="utf-8")


def test_bake_ignores_stray_readme_base_and_hidden(tmp_path):
    """generate_bake emits targets only for real profiles.

    Regression guard for the actual bug: a ``README.md`` / ``base`` / dotfile
    in ``generated/profiles`` must NOT produce a ``final-<name>`` target.
    """
    count, hcl = _run_bake(tmp_path)

    assert count == 2
    assert 'target "final-dev"' in hcl
    assert 'target "final-quarto-full"' in hcl
    assert "final-README" not in hcl
    assert "final-base" not in hcl
    assert "final-.gitkeep" not in hcl
    assert "final-subdir" not in hcl


def test_bake_group_targets_match_profile_set(tmp_path):
    """The ``all`` group lists exactly the real profiles, nothing stray."""
    _, hcl = _run_bake(tmp_path)

    group_block = hcl.split('group "all"')[1].split("}")[0]
    assert '"final-dev"' in group_block
    assert '"final-quarto-full"' in group_block
    assert "final-README" not in group_block
    assert "final-base" not in group_block


# --- bake set == dockerfile set (derived from the shared predicate) -----------


def test_bake_and_dockerfile_derive_identical_profile_set(tmp_path):
    """Given one directory listing, both generators select the same names.

    Bake builds its list inline (``generate_bake``); the Dockerfile generator
    builds a set over ``(profiles/, generated/profiles/)``. Both are driven by
    ``is_profile_file``, so for an identical set of files the selected profile
    names must be equal.
    """
    profiles_dir = tmp_path / "generated" / "profiles"
    profiles_dir.mkdir(parents=True)
    for name in ("dev", "quarto-full", "lang-java-25", "README.md", "base"):
        _make_profile(name, profiles_dir)
    (profiles_dir / ".gitkeep").write_text("", encoding="utf-8")

    # Bake's view: run the real generator and read the returned count / targets.
    out = tmp_path / "docker-bake.hcl"
    with patch(
        "solen.generators.bake.get_version_tags",
        return_value=("develop", "develop-94457ad"),
    ), patch("solen.generators.bake.get_git_sha", return_value="94457ad"):
        bake_count = generate_bake(tmp_path, out)
    bake_targets = {
        line.strip().split('"')[1].removeprefix("final-")
        for line in out.read_text(encoding="utf-8").splitlines()
        if line.strip().startswith('target "final-')
    }

    # Dockerfile's view: the same comprehension generate_dockerfile uses.
    top_profiles = tmp_path / "profiles"
    dockerfile_names = {
        p.name
        for d in (top_profiles, profiles_dir)
        if d.exists()
        for p in d.iterdir()
        if is_profile_file(p)
    }

    assert bake_targets == dockerfile_names == {"dev", "quarto-full", "lang-java-25"}
    assert bake_count == len(dockerfile_names) == 3
