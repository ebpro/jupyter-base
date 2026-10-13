"""Tests for the dormant ``@parent`` stage-chaining helpers.

Covers the pure helpers added to :mod:`solen.generators.dockerfile_gen` for the
layer-sharing feature:

* :func:`read_parent_name` — read the direct ``@parent:`` declaration from a
  profile file (no chain resolution).
* :func:`compute_install_features` — the per-stage install set: the full
  expanded set with no parent, only the delta with a parent.

Both are exercised against a minimal on-disk ``features/`` fixture built with
``tmp_path`` so the tests are deterministic and independent of the repository
tree. The no-parent install-order assertions compare sets (not lists) because
the input is a set and :func:`topological_sort_features` tie-breaks independent
features by iteration order. The with-parent path is now deterministic (the
delta is sorted before the topological sort), so those tests assert the exact
order and, separately, that two calls with the same inputs are equal.
"""

import json
import re
from pathlib import Path

import pytest

import solen.generators.dockerfile_gen as dockerfile_gen
from solen.generators.dockerfile_gen import (
    build_profile_data,
    compute_install_features,
    order_profiles_parent_first,
    read_parent_name,
    render_template,
)


def _make_features_dir(base_dir, feature_ids):
    """Create ``<base_dir>/features/<fid>/feature.json`` for each feature id."""
    features_dir = base_dir / "features"
    features_dir.mkdir(parents=True, exist_ok=True)
    for fid in feature_ids:
        feature_dir = features_dir / fid
        feature_dir.mkdir(parents=True, exist_ok=True)
        (feature_dir / "feature.json").write_text(
            json.dumps({"id": fid, "name": fid, "version": "0.0.0", "dependsOn": []}),
            encoding="utf-8",
        )
    return features_dir


def test_read_parent_name_returns_declared_parent(tmp_path):
    """A profile declaring ``@parent: foo`` (plus feature lines) returns ``foo``."""
    profile_file = tmp_path / "child"
    profile_file.write_text("@parent: foo\nalpha\nbeta\n", encoding="utf-8")
    assert read_parent_name(profile_file) == "foo"


def test_read_parent_name_absent_returns_none(tmp_path):
    """A profile with no ``@parent:`` line returns ``None``."""
    profile_file = tmp_path / "standalone"
    profile_file.write_text("alpha\nbeta\n", encoding="utf-8")
    assert read_parent_name(profile_file) is None


def test_compute_install_features_no_parent_returns_full_set(tmp_path):
    """Without a parent, the install set is the full (expanded) set."""
    features_dir = _make_features_dir(tmp_path, ["alpha", "beta", "gamma"])
    all_expanded = {"alpha", "beta", "gamma"}
    result = compute_install_features(features_dir, all_expanded, None)
    assert set(result) == all_expanded
    assert len(result) == len(all_expanded)


def test_compute_install_features_with_parent_returns_delta(tmp_path):
    """With a parent, only the delta (all minus the ancestor's set) is installed."""
    features_dir = _make_features_dir(tmp_path, ["alpha", "beta", "gamma", "delta"])
    all_expanded = {"alpha", "beta", "gamma", "delta"}
    parent_expanded = {"alpha", "beta"}
    result = compute_install_features(features_dir, all_expanded, parent_expanded)
    assert set(result) == {"gamma", "delta"}
    assert len(result) == 2


def test_compute_install_features_no_parent_matches_topo_sort(tmp_path):
    """The no-parent branch is byte-identical to ``topological_sort_features``.

    Passing the original (deterministic) expanded list with ``parent_expanded``
    as ``None`` must return exactly what ``topological_sort_features`` returns
    for that same list — i.e. the no-parent output is unchanged.
    """
    from solen.core.feature import topological_sort_features

    features_dir = _make_features_dir(tmp_path, ["alpha", "beta", "gamma"])
    expanded = ["gamma", "alpha", "beta"]  # a specific, non-alphabetical order
    result = compute_install_features(features_dir, expanded, None)
    expected = topological_sort_features(features_dir, expanded)
    assert result == expected


def test_compute_install_features_with_parent_is_deterministic(tmp_path):
    """With a parent, the install order is deterministic (independent of hash order).

    Uses several independent features so the ``sorted()`` tie-break is
    exercised. The delta is sorted alphabetically before the topological sort,
    so two calls with the same inputs (even a ``set`` input) yield the same
    order.
    """
    features_dir = _make_features_dir(
        tmp_path,
        ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"],
    )
    # Pass a set to mirror the historical (non-deterministic) call shape.
    all_expanded = {"alpha", "beta", "gamma", "delta", "epsilon", "zeta"}
    parent_expanded = {"alpha", "beta"}
    result1 = compute_install_features(features_dir, all_expanded, parent_expanded)
    result2 = compute_install_features(features_dir, all_expanded, parent_expanded)
    # Two calls with the same inputs are equal (same order).
    assert result1 == result2
    # The exact order: the delta is sorted alphabetically, then topo-sorted.
    assert set(result1) == {"gamma", "delta", "epsilon", "zeta"}
    assert result1 == sorted(["gamma", "delta", "epsilon", "zeta"])


def test_new_style_validation_matrix_generates_parent_profile(tmp_path):
    """A new-style matrix (``profiles:`` list) with ``parent: dev`` produces a
    profile file containing ``@parent:dev`` and the ``hadolint`` line.

    Mirrors ``profiles/matrix/layer-share-validation.yaml``.
    """
    from solen.generators.profiles import generate_profiles

    matrix_yaml = (
        "profiles:\n"
        "  - base: lsval\n"
        "    parent: dev\n"
        "    labels:\n"
        "      hadolint:\n"
        "        features:\n"
        "          - hadolint\n"
        "        options: {}\n"
    )
    matrix_path = tmp_path / "matrix.yaml"
    matrix_path.write_text(matrix_yaml, encoding="utf-8")

    out_dir = tmp_path / "out"
    generate_profiles(matrix_path, out_dir)

    profile_file = out_dir / "lsval-hadolint"
    assert profile_file.exists()
    content = profile_file.read_text(encoding="utf-8")
    assert "@parent:dev" in content
    assert "hadolint" in content


def test_legacy_variant_parent_overrides_and_falls_back(tmp_path):
    """Legacy ``matrix:`` format: a variant-level ``parent:`` key wins over
    the top-level ``parent:`` for that variant, while variants without one
    fall back to the top-level value.

    ``base`` is pinned so the top-level-parent base derivation does not
    interfere with the name assertions.
    """
    from solen.generators.profiles import generate_profiles

    matrix_yaml = (
        "base: family\n"
        "parent: top-parent\n"
        "matrix:\n"
        "  one:\n"
        "    parent: variant-parent\n"
        "    features:\n"
        "      - alpha\n"
        "  two:\n"
        "    features:\n"
        "      - beta\n"
    )
    matrix_path = tmp_path / "matrix.yaml"
    matrix_path.write_text(matrix_yaml, encoding="utf-8")

    out_dir = tmp_path / "out"
    generate_profiles(matrix_path, out_dir)

    content_one = (out_dir / "family-one").read_text(encoding="utf-8")
    assert "@parent:variant-parent" in content_one
    assert "@parent:top-parent" not in content_one

    content_two = (out_dir / "family-two").read_text(encoding="utf-8")
    assert "@parent:top-parent" in content_two


def test_legacy_variant_parent_does_not_rename_siblings(tmp_path):
    """A variant-level parent must not trigger the top-level base derivation:
    with no top-level ``parent:``, every profile keeps its label as its name
    (mirrors ``quarto-lecture.yaml``, where only ``quarto-full`` gains a
    parent while ``quarto`` and ``quarto-java-25`` stay untouched).
    """
    from solen.generators.profiles import generate_profiles

    matrix_yaml = (
        "matrix:\n"
        "  quarto:\n"
        "    features:\n"
        "      - alpha\n"
        "  quarto-full:\n"
        "    parent: quarto-java-25\n"
        "    features:\n"
        "      - beta\n"
        "  quarto-java-25:\n"
        "    features:\n"
        "      - alpha\n"
    )
    matrix_path = tmp_path / "matrix.yaml"
    matrix_path.write_text(matrix_yaml, encoding="utf-8")

    out_dir = tmp_path / "out"
    generate_profiles(matrix_path, out_dir)

    assert sorted(p.name for p in out_dir.iterdir()) == [
        "quarto",
        "quarto-full",
        "quarto-java-25",
    ]
    assert "@parent:quarto-java-25" in (out_dir / "quarto-full").read_text(encoding="utf-8")
    assert "@parent" not in (out_dir / "quarto").read_text(encoding="utf-8")
    assert "@parent" not in (out_dir / "quarto-java-25").read_text(encoding="utf-8")


def test_legacy_matrix_without_any_parent_stays_parentless(tmp_path):
    """Backward compatibility: a legacy matrix with no parent at either level
    generates profiles with no ``@parent:`` line at all — byte-identical to
    pre-change behavior.
    """
    from solen.generators.profiles import generate_profiles

    matrix_yaml = (
        "matrix:\n"
        "  plain:\n"
        "    features:\n"
        "      - alpha\n"
        "      - beta\n"
        "    options: {}\n"
    )
    matrix_path = tmp_path / "matrix.yaml"
    matrix_path.write_text(matrix_yaml, encoding="utf-8")

    out_dir = tmp_path / "out"
    generate_profiles(matrix_path, out_dir)

    content = (out_dir / "plain").read_text(encoding="utf-8")
    assert "@parent" not in content
    assert "# Source matrix:" in content
    assert "alpha\n" in content and "beta\n" in content


# --- Stage ordering: parent-before-child (topological) ---------------------
#
# Additive coverage for ``order_profiles_parent_first`` and the
# ``_parent_chain_root_first`` chain used by the single-profile generator.
# Without these, the Dockerfile emitted ``FROM final-quarto-java-25 AS
# profile-quarto-full`` ~560 lines BEFORE ``final-quarto-java-25`` was
# defined, which BuildKit rejects ("base name ... not defined").


def test_order_parent_emitted_before_child():
    """A child is never emitted before its parent, even when it sorts first."""
    from solen.generators.dockerfile_gen import order_profiles_parent_first

    # Mirrors the real defect: "quarto-full" < "quarto-java-25" alphabetically.
    parents = {
        "quarto-full": "quarto-java-25",
        "quarto-java-25": None,
        "alpha": None,
    }
    result = order_profiles_parent_first(set(parents), parents)
    assert result.index("quarto-java-25") < result.index("quarto-full")
    assert result == ["alpha", "quarto-java-25", "quarto-full"]


def test_order_deep_chain_emits_root_most_first():
    """A chain child -> ... -> root is emitted root-most first, in full."""
    from solen.generators.dockerfile_gen import order_profiles_parent_first

    parents = {
        "child3": "child2",
        "child2": "child1",
        "child1": "root",
        "root": None,
        "aaa": None,
        "zzz": None,
    }
    result = order_profiles_parent_first(set(parents), parents)
    assert result == ["aaa", "root", "child1", "child2", "child3", "zzz"]
    idx = {name: i for i, name in enumerate(result)}
    assert idx["root"] < idx["child1"] < idx["child2"] < idx["child3"]


def test_order_no_parent_profiles_keep_exact_alphabetical_positions():
    """Minimal churn: only a parent pulled toward an earlier child moves.

    ``dev`` -> ``lsval`` is already alphabetical-correct and must NOT move;
    only ``quarto-java-25`` jumps ahead of its alphabetically-earlier child
    ``quarto-full``. Every other stage keeps its relative order.
    """
    from solen.generators.dockerfile_gen import order_profiles_parent_first

    parents = {
        "alpha": None,
        "dev": None,
        "lsval": "dev",
        "quarto": None,
        "quarto-full": "quarto-java-25",
        "quarto-java-25": None,
        "zeta": None,
    }
    result = order_profiles_parent_first(set(parents), parents)
    assert result == [
        "alpha",
        "dev",
        "lsval",  # stays at its alphabetical slot (dev already precedes it)
        "quarto",
        "quarto-java-25",  # pulled forward, one slot, to precede its child
        "quarto-full",
        "zeta",
    ]


def test_order_is_deterministic_across_input_orders():
    """Set vs shuffled-list inputs (and repeated calls) yield the same order.

    Guards the Dockerfile against filesystem ``iterdir()`` order.
    """
    from solen.generators.dockerfile_gen import order_profiles_parent_first

    parents = {
        "b": "a",
        "a": None,
        "c": None,
        "quarto-full": "quarto-java-25",
        "quarto-java-25": None,
    }
    expected = ["a", "b", "c", "quarto-java-25", "quarto-full"]
    shuffled = ["quarto-full", "c", "quarto-java-25", "b", "a"]
    assert order_profiles_parent_first(set(parents), parents) == expected
    assert order_profiles_parent_first(shuffled, parents) == expected
    assert order_profiles_parent_first(list(reversed(shuffled)), parents) == expected
    # Two identical calls are equal (no hidden state).
    assert order_profiles_parent_first(set(parents), parents) == expected


def test_order_empty_input_returns_empty():
    """Degenerate empty profile set orders to an empty list."""
    from solen.generators.dockerfile_gen import order_profiles_parent_first

    assert order_profiles_parent_first(set(), {}) == []


def test_order_cycle_raises_value_error():
    """A parent cycle fails loudly instead of looping or dropping stages."""
    from solen.generators.dockerfile_gen import order_profiles_parent_first

    parents = {"a": "b", "b": "a"}
    with pytest.raises(ValueError, match="cycle"):
        order_profiles_parent_first(set(parents), parents)

    # Self-cycle too.
    with pytest.raises(ValueError, match="cycle"):
        order_profiles_parent_first({"x"}, {"x": "x"})


def test_order_missing_parent_raises_value_error():
    """A parent outside the profile set fails loudly."""
    from solen.generators.dockerfile_gen import order_profiles_parent_first

    parents = {"a": "ghost", "b": None}
    with pytest.raises(ValueError, match="unknown parent 'ghost'"):
        order_profiles_parent_first(set(parents), parents)


# --- Single-profile Dockerfile: the parent chain must be emitted -----------


def _write_parented_profiles(repo_root, declarations):
    """Create ``<repo_root>/profiles/<name>`` files for name -> parent pairs."""
    profiles_dir = repo_root / "profiles"
    profiles_dir.mkdir(parents=True, exist_ok=True)
    for name, parent in declarations.items():
        lines = [f"@parent:{parent}\n"] if parent else []
        lines.append("alpha\n")
        (profiles_dir / name).write_text("".join(lines), encoding="utf-8")


def test_parent_chain_root_first_for_deep_chain(tmp_path):
    """c3 -> c2 -> c1 (no parent) resolves to [c1, c2, c3] (root-most first)."""
    from solen.generators.dockerfile_gen import _parent_chain_root_first

    _write_parented_profiles(
        tmp_path, {"c1": None, "c2": "c1", "c3": "c2"}
    )
    assert _parent_chain_root_first(tmp_path, "c3") == ["c1", "c2", "c3"]


def test_parent_chain_root_first_parentless_is_single(tmp_path):
    """A parentless profile's chain is exactly itself (unchanged behaviour)."""
    from solen.generators.dockerfile_gen import _parent_chain_root_first

    _write_parented_profiles(tmp_path, {"solo": None})
    assert _parent_chain_root_first(tmp_path, "solo") == ["solo"]


def test_parent_chain_root_first_cycle_raises(tmp_path):
    """An on-disk parent cycle fails loudly instead of looping."""
    from solen.generators.dockerfile_gen import _parent_chain_root_first

    _write_parented_profiles(tmp_path, {"p1": "p2", "p2": "p1"})
    with pytest.raises(ValueError, match="cycle"):
        _parent_chain_root_first(tmp_path, "p1")


# --- End-to-end ordering through the REAL generator -------------------------
#
# The ``order_profiles_parent_first`` tests above use hand-built dicts, so the
# wiring real-profile-files -> ``parents`` map -> emission order -> rendered
# Dockerfile TEXT was unproven. These tests drive the real pipeline
# (``build_profile_data`` + ``order_profiles_parent_first`` + ``render_template``)
# over an on-disk fixture whose CHILD sorts alphabetically BEFORE its PARENT
# (mirroring quarto-full < quarto-java-25) and assert on the emitted text that
# every internal ``FROM <alias>`` refers to an alias already defined at a
# strictly lower line number. ``test_ordering_regression_against_alphabetical``
# is the non-tautology proof: the same fixture rendered with the OLD plain
# alphabetical order MUST violate the invariant.

_REPO_ROOT = Path(__file__).resolve().parents[2]


def _make_parented_fixture_repo(tmp_path):
    """Build a minimal repo_root fixture: profiles + features + template access.

    Layout::

        tmp_path/profiles/zeta-parent      # parent (sorts AFTER the child)
        tmp_path/profiles/alpha-child      # @parent:zeta-parent (sorts FIRST)
        tmp_path/features/{alpha,beta,gamma}/feature.json
        tmp_path/solen-cli -> <repo>/solen-cli   # so render_template finds the
                                                   # real dockerfile_template.j2

    Returns ``tmp_path`` usable as ``repo_root``.
    """
    _make_features_dir(tmp_path, ["alpha", "beta", "gamma"])
    profiles_dir = tmp_path / "profiles"
    profiles_dir.mkdir(parents=True, exist_ok=True)
    (profiles_dir / "zeta-parent").write_text("alpha\nbeta\n", encoding="utf-8")
    (profiles_dir / "alpha-child").write_text(
        "@parent:zeta-parent\nbeta\ngamma\n", encoding="utf-8"
    )
    # render_template resolves the template at
    # ``repo_root/solen-cli/solen/generators``; symlink the real package dir so
    # the fixture renders the authoritative template without copying it.
    generators_pkg_dir = Path(dockerfile_gen.__file__).parents[2]  # .../solen-cli
    (tmp_path / "solen-cli").symlink_to(generators_pkg_dir)
    return tmp_path


def _render_ordered(repo_root, emit_order):
    """Render the fixture Dockerfile with the given explicit emission order."""
    data = {name: build_profile_data(repo_root, name) for name in emit_order}
    return render_template(repo_root, [data[name] for name in emit_order])


def _forward_internal_refs(text):
    """Return (line, alias, definition-line) for every bad internal FROM ref.

    An internal alias is any name defined by ``FROM <src> AS <alias>`` (base,
    profile-*, final-*). A reference is bad when its ``FROM <alias>`` appears
    at a line that is NOT strictly greater than the alias's first definition
    (forward reference, self-reference, or reference to an undefined alias
    which BuildKit would reject as "base name ... not defined").
    """
    definitions = {}
    for lineno, line in enumerate(text.splitlines(), start=1):
        match = re.match(r"FROM\s+\S+\s+AS\s+(\S+)\s*$", line)
        if match and match.group(1) not in definitions:
            definitions[match.group(1)] = lineno
    bad = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        match = re.match(r"FROM\s+(\S+)(?:\s+AS\s+\S+)?\s*$", line)
        if not match:
            continue
        src = match.group(1)
        if src in definitions and definitions[src] >= lineno:
            bad.append((lineno, src, definitions[src]))
        elif src.startswith(("profile-", "final-")) and src not in definitions:
            bad.append((lineno, src, None))
    return bad


def _stage_emission_order(text):
    """Profile stage names in the order their ``AS profile-<name>`` appear."""
    return [
        match.group(1)
        for match in (
            re.match(r"FROM\s+\S+\s+AS\s+profile-(\S+)\s*$", line)
            for line in text.splitlines()
        )
        if match
    ]


def test_real_generator_emits_parent_before_child(tmp_path):
    """End-to-end: real files -> parents map -> order -> rendered text.

    The child ``alpha-child`` sorts before parent ``zeta-parent``; the emitted
    Dockerfile must still define ``final-zeta-parent`` before ``alpha-child``
    references it, and no internal FROM may forward-reference at all.
    """
    repo_root = _make_parented_fixture_repo(tmp_path)
    names = {"zeta-parent", "alpha-child"}
    parents = {
        name: read_parent_name(repo_root / "profiles" / name) for name in names
    }
    assert parents == {"zeta-parent": None, "alpha-child": "zeta-parent"}

    ordered = order_profiles_parent_first(names, parents)
    text = _render_ordered(repo_root, ordered)

    assert _forward_internal_refs(text) == []
    assert _stage_emission_order(text) == ["zeta-parent", "alpha-child"]
    # The exact defect shape: the child's FROM final-zeta-parent reference
    # must sit strictly below the parent's final-stage definition.
    lines = text.splitlines()
    def_line = next(
        i for i, ln in enumerate(lines) if "AS final-zeta-parent" in ln
    )
    ref_line = next(
        i for i, ln in enumerate(lines)
        if ln.startswith("FROM final-zeta-parent AS profile-alpha-child")
    )
    assert def_line < ref_line


def test_real_generator_output_is_byte_identical_across_runs(tmp_path):
    """Two consecutive full-pipeline renders produce identical bytes."""
    repo_root = _make_parented_fixture_repo(tmp_path)
    names = {"zeta-parent", "alpha-child"}
    parents = {
        name: read_parent_name(repo_root / "profiles" / name) for name in names
    }
    ordered = order_profiles_parent_first(names, parents)
    assert _render_ordered(repo_root, ordered) == _render_ordered(repo_root, ordered)


def test_ordering_regression_against_alphabetical(tmp_path):
    """Non-tautology proof: plain alphabetical order breaks the invariant.

    Renders the SAME fixture in the OLD plain-sorted emission order (child
    before parent) and asserts the forward-reference detector fires. If this
    test ever goes green without a template change, the ordering machinery
    became irrelevant and the suite should be revisited.
    """
    repo_root = _make_parented_fixture_repo(tmp_path)
    alphabetical = sorted({"zeta-parent", "alpha-child"})  # alpha-child first
    assert alphabetical == ["alpha-child", "zeta-parent"]

    text = _render_ordered(repo_root, alphabetical)

    bad = _forward_internal_refs(text)
    assert bad, "alphabetical order unexpectedly produced a valid Dockerfile"
    ref_lines = [lineno for lineno, alias, _def in bad]
    offending = [
        (lineno, alias)
        for lineno, alias, _def in bad
        if alias == "final-zeta-parent"
    ]
    assert offending, f"expected a forward ref to final-zeta-parent, got {bad}"
    # Sanity: the detector only flags real FROM lines.
    for lineno in ref_lines:
        assert text.splitlines()[lineno - 1].startswith("FROM ")


# --- Inherited options: quarto-full <- quarto-java-25 -----------------------


def test_quarto_full_inherits_kernel_version_from_quarto_java_25(tmp_path):
    """Pin the silent inheritance that keeps the shared layer coherent.

    ``quarto-full`` declares only ``JDK_VERSION``; ``KERNEL_VERSION`` and
    ``ARTIFACTS_BASE_URL`` must resolve via ``@parent:`` from
    ``quarto-java-25``. A future change on EITHER side that alters this set
    or these values must fail HERE, not silently desync the child's ENV from
    the parent layer it is built on. Also pins that the sibling
    ``quarto-java-ea`` keeps its own (now aligned) ``v1.4.6-pr12`` (no parent).
    """
    from solen.core.profile import parse_profile
    from solen.generators.profiles import generate_profiles

    out_dir = tmp_path / "profiles"
    matrix = _REPO_ROOT / "profiles" / "matrix" / "quarto-lecture.yaml"
    generated = generate_profiles(matrix, out_dir)
    assert generated > 0

    child_file = out_dir / "quarto-full"
    assert "@parent:quarto-java-25" in child_file.read_text(encoding="utf-8")

    resolved = parse_profile(child_file, out_dir)

    # Exact key set: parent-inherited + child-own (+ top-level matrix option).
    assert set(resolved.options) == {
        "INSTALL_NOTEBOOK_EXTENSIONS",  # top-level matrix option
        "KERNEL_VERSION",  # inherited from quarto-java-25
        "ARTIFACTS_BASE_URL",  # inherited from quarto-java-25
        "JDK_VERSION",  # declared by the child itself
    }

    # Inherited values, pinned to the Source-of-Truth version.
    assert resolved.options["KERNEL_VERSION"] == "v1.4.6-pr12"
    assert resolved.options["ARTIFACTS_BASE_URL"] == (
        "https://github.com/ebpro/IJava/releases"
    )
    assert resolved.options["JDK_VERSION"] == "25"

    # The child must NOT re-declare the inherited keys: a child-side override
    # would set the ENV while the layer was built from the parent's (possibly
    # different) value -- the silent mismatch this test exists to catch.
    child_own = child_file.read_text(encoding="utf-8")
    assert "KERNEL_VERSION" not in child_own
    assert "ARTIFACTS_BASE_URL" not in child_own

    # The parent resolves the same value the child inherits (consistency).
    parent_resolved = parse_profile(out_dir / "quarto-java-25", out_dir)
    assert parent_resolved.options["KERNEL_VERSION"] == "v1.4.6-pr12"

    # Sibling without a parent keeps its own explicit pin (aligned to the
    # same kernel version as the quarto-java family).
    ea_resolved = parse_profile(out_dir / "quarto-java-ea", out_dir)
    assert ea_resolved.options["KERNEL_VERSION"] == "v1.4.6-pr12"


# --- Layer sharing on the REAL matrix: @parent removes rebuilt layers -------
#
# The entire point of ``@parent`` layer sharing is that a child stage does NOT
# rebuild feature layers its parent already installed. This was verified by
# inspection of the generated Dockerfile (``profile-quarto-full`` carries zero
# ``java-*`` feature mounts while ``profile-quarto-java-25`` carries five),
# but nothing encoded it. If a refactor re-introduced the ``java-*`` mounts
# into the child's delta -- rebuilding the full LaTeX/Java stack on every
# child, exactly the regression the feature exists to prevent -- the rest of
# the suite would still pass. These tests drive the REAL multi-profile
# pipeline (``generate_multi_profile_dockerfile``) over copies of the real
# matrices into a ``tmp_path`` repo root, so they need no ``generated/`` on
# disk (it is gitignored and absent on a fresh clone) and never write into the
# repository. ``test_dropping_parent_edge_restores_java_layers_in_child_stage``
# is the non-tautology proof in the spirit of
# ``test_ordering_regression_against_alphabetical``: the SAME machinery, run
# against a tmp copy of the matrices with the ``parent: quarto-java-25`` key
# removed, must make the ``java-*`` mounts reappear.

#: The five java-* features the real matrix installs in the parent stage.
#: Verified against in-process generation of the real matrices (not against
#: ``generated/``, which is gitignored). The child stage must rebuild none.
_REAL_PARENT_JAVA_FEATURES = [
    "java-gradle",
    "java-jdk",
    "java-kernel",
    "java-maven",
    "java-sdkman",
]

#: Exact line removed in the tmp copy for the perturbation test. Pinned as a
#: literal so a future matrix refactor fails the helper loudly instead of
#: silently turning the perturbation (and its proof) into a no-op.
_QUARTO_FULL_PARENT_DECL = "    parent: quarto-java-25\n"


def _materialize_real_repo(tmp_path, *, drop_quarto_full_parent_edge=False):
    """Assemble a throwaway repo_root in ``tmp_path`` and render the real Dockerfile.

    Layout::

        tmp_path/features   -> symlink to the real features/   (read-only)
        tmp_path/solen-cli  -> symlink to the real solen-cli/  (template SoT)
        tmp_path/profiles/matrix/*.yaml  -- COPIES of the real matrices
                               (perturbable; the repo is never modified)

    ``generate_multi_profile_dockerfile`` then generates profiles into
    ``tmp_path/generated/profiles`` and writes the Dockerfile to
    ``tmp_path/Dockerfile`` -- every write stays inside ``tmp_path``. The
    repository's own ``generated/`` is neither read nor regenerated.

    Returns ``(dockerfile_text, generated_profiles_dir)``.
    """
    from solen.generators.dockerfile_gen import generate_multi_profile_dockerfile

    (tmp_path / "features").symlink_to(_REPO_ROOT / "features")
    (tmp_path / "solen-cli").symlink_to(_REPO_ROOT / "solen-cli")

    matrix_src = _REPO_ROOT / "profiles" / "matrix"
    matrix_dst = tmp_path / "profiles" / "matrix"
    matrix_dst.mkdir(parents=True)
    perturbed = False
    for matrix in sorted(matrix_src.glob("*.y*ml")):
        text = matrix.read_text(encoding="utf-8")
        if drop_quarto_full_parent_edge and matrix.name == "quarto-lecture.yaml":
            assert _QUARTO_FULL_PARENT_DECL in text, (
                "perturbation pin drifted: the exact parent declaration is "
                "no longer in quarto-lecture.yaml; update the helper AND "
                "re-check that the layer-sharing tests still discriminate"
            )
            text = text.replace(_QUARTO_FULL_PARENT_DECL, "")
            perturbed = True
        (matrix_dst / matrix.name).write_text(text, encoding="utf-8")
    if drop_quarto_full_parent_edge:
        assert perturbed, "quarto-lecture.yaml was not found in the real matrix dir"

    dockerfile_path = tmp_path / "Dockerfile"
    generate_multi_profile_dockerfile(tmp_path, dockerfile_path)
    return dockerfile_path.read_text(encoding="utf-8"), tmp_path / "generated" / "profiles"


def _parse_dockerfile_stages(text):
    """Map every stage alias to ``(from_source, feature_mount_ids_in_order)``.

    A stage body spans from its ``FROM <src> AS <alias>`` line to the next
    stage header. Feature mounts are the BuildKit bind mounts the template
    emits per installed feature:
    ``--mount=type=bind,source=features/<id>,target=...``.
    """
    lines = text.splitlines()
    headers = []
    for lineno, line in enumerate(lines):
        match = re.match(r"FROM\s+(\S+)\s+AS\s+(\S+)\s*$", line)
        if match:
            headers.append((lineno, match.group(1), match.group(2)))
    stages = {}
    for idx, (lineno, src, alias) in enumerate(headers):
        end = headers[idx + 1][0] if idx + 1 < len(headers) else len(lines)
        body = "\n".join(lines[lineno + 1 : end])
        mounts = re.findall(r"--mount=type=bind,source=features/([^,]+),", body)
        stages[alias] = (src, mounts)
    return stages


def _real_profile_parent_map(generated_profiles_dir):
    """``profile name -> direct @parent (or None)`` for the real generated set.

    Uses the generator's own profile-file predicate and parent reader, so the
    map reflects exactly what the Dockerfile pipeline saw.
    """
    from solen.core.profile import is_profile_file

    return {
        path.name: read_parent_name(path)
        for path in sorted(generated_profiles_dir.iterdir())
        if is_profile_file(path)
    }


def test_real_matrix_quarto_full_rebuilds_zero_java_layers_parent_rebuilds_five(
    tmp_path,
):
    """The headline layer-sharing fact, encoded: 0 java-* mounts in the child.

    ``profile-quarto-full`` is built ``FROM final-quarto-java-25`` and must
    carry ZERO ``java-*`` feature mounts, while its parent stage
    ``profile-quarto-java-25`` (``FROM base``) carries exactly the five the
    real matrix installs. If the delta computation regressed to "re-install
    everything", the child's java-* list becomes non-empty and this fails.
    """
    text, profiles_dir = _materialize_real_repo(tmp_path)
    stages = _parse_dockerfile_stages(text)

    child_src, child_mounts = stages["profile-quarto-full"]
    parent_src, parent_mounts = stages["profile-quarto-java-25"]

    # The child builds ON the parent stage, not on base.
    assert child_src == "final-quarto-java-25"
    assert parent_src == "base"

    child_java = sorted(f for f in child_mounts if f.startswith("java-"))
    parent_java = sorted(f for f in parent_mounts if f.startswith("java-"))
    assert child_java == []
    assert parent_java == _REAL_PARENT_JAVA_FEATURES
    assert len(parent_java) == 5

    # Zero sharing at all: the child must not re-mount ANY feature the parent
    # mounted (stronger than the java-* pin, same mechanism).
    assert set(child_mounts) & set(parent_mounts) == set()


def test_every_parent_edge_child_mounts_disjoint_and_chains_to_parent(tmp_path):
    """Parent-agnostic invariant, so future ``@parent`` edges are covered by data.

    For EVERY profile that declares a parent, in the real rendered Dockerfile:
    (a) its stage is ``FROM final-<parent>``, and
    (b) its feature mounts are disjoint from the parent stage's mounts --
    a child never rebuilds a layer any ancestor already installed.
    The final assertion guards against the edge set silently becoming empty
    (which would make the loop vacuously true).
    """
    text, profiles_dir = _materialize_real_repo(tmp_path)
    stages = _parse_dockerfile_stages(text)
    parents = _real_profile_parent_map(profiles_dir)

    edges = {name: parent for name, parent in parents.items() if parent is not None}
    for name, parent in edges.items():
        child_src, child_mounts = stages[f"profile-{name}"]
        parent_src, parent_mounts = stages[f"profile-{parent}"]
        assert child_src == f"final-{parent}", (
            f"profile-{name} must build FROM final-{parent}, got {child_src}"
        )
        overlap = set(child_mounts) & set(parent_mounts)
        assert overlap == set(), (
            f"layer-sharing broken: profile-{name} re-mounts features its "
            f"parent {parent} already installed: {sorted(overlap)}"
        )
    assert edges, "no @parent edges in the real matrix: this test went vacuous"


def test_parentless_profile_stages_all_still_build_from_base(tmp_path):
    """No over-chaining: every parentless profile still starts at ``base``.

    Guards the opposite failure of the previous test -- a change that wired
    ``FROM final-...`` into profiles that never declared a parent. The 30/31
    split is the verified current reality (exactly one parent edge:
    quarto-full -> quarto-java-25); if a future matrix legitimately renames a
    profile the counts update, but a parentless stage must NEVER come FROM a
    final-* alias.
    """
    text, profiles_dir = _materialize_real_repo(tmp_path)
    stages = _parse_dockerfile_stages(text)
    parents = _real_profile_parent_map(profiles_dir)

    parentless = sorted(n for n, p in parents.items() if p is None)
    assert len(parentless) == 30
    assert len(parents) == 31  # 30 parentless + exactly one parented child
    for name in parentless:
        src, _mounts = stages[f"profile-{name}"]
        assert src == "base", f"profile-{name} declares no parent but builds {src}"


def test_dropping_parent_edge_restores_java_layers_in_child_stage(tmp_path):
    """Non-tautology proof: without the edge, the SAME checks must flip.

    Runs the identical machinery against a tmp copy of the real matrices with
    ``parent: quarto-java-25`` removed from ``quarto-lecture.yaml``. Then
    ``profile-quarto-full`` is parentless: it builds ``FROM base`` and rebuilds
    the full java-* stack -- exactly the five mounts the positive test pins as
    absent. If this test ever goes green while the mounts stay absent, the
    positive assertions pass for the wrong reason and the suite is dead weight.
    """
    text, _profiles_dir = _materialize_real_repo(
        tmp_path, drop_quarto_full_parent_edge=True
    )
    stages = _parse_dockerfile_stages(text)

    child_src, child_mounts = stages["profile-quarto-full"]
    child_java = sorted(f for f in child_mounts if f.startswith("java-"))

    assert child_src == "base"
    assert child_java == _REAL_PARENT_JAVA_FEATURES, (
        "perturbation did not restore the java-* layers in the child stage -- "
        "the 0-count in the positive test is not caused by the parent edge"
    )
