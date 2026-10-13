"""Unit tests for the layer-sharing analysis (FROM-layer sharing DAG).

Covers the pure, I/O-free functions in :mod:`solen.generators.layersharing`:
cover (direct base) computation, transitive-ancestor closure, per-edge gain
metrics, the topological prefix check, representative chain selection, Mermaid
id sanitisation / edge de-duplication, table ordering and Markdown rendering.

All tests use small in-memory feature-set dicts (plus a monkeypatched
topological sort where the prefix check needs a ``features_dir``), so they are
deterministic and independent of the repository tree. Every assertion
constrains production *output*: none restates a property of the fixture, and
none is evaluated over a collection the fixture leaves empty.

The final test is the only one that is not pure: it drives the ``analyze
layer-sharing`` CLI against an empty (tmp_path) repo root to pin the
empty-profile-set guard.
"""

from pathlib import Path

from click.testing import CliRunner

from solen.cli import cli
from solen.generators import layersharing
from solen.generators.layersharing import (
    EdgeGain,
    analyze_layer_sharing,
    compute_direct_bases,
    render_markdown,
    sanitize_id,
    transitive_ancestors,
)

# ---------------------------------------------------------------------------
# compute_direct_bases (cover relation of the subset poset)
# ---------------------------------------------------------------------------


def test_compute_direct_bases_chain():
    """A⊂B⊂C: covers are (A,B) and (B,C), NOT the transitive (A,C)."""
    fs = {
        "A": {"1"},
        "B": {"1", "2"},
        "C": {"1", "2", "3"},
    }
    assert compute_direct_bases(fs) == [("A", "B"), ("B", "C")]


def test_compute_direct_bases_diamond():
    """A⊂B, A⊂C, D = B∪C: covers are (A,B),(A,C),(B,D),(C,D)."""
    fs = {
        "A": {"1"},
        "B": {"1", "2"},
        "C": {"1", "3"},
        "D": {"1", "2", "3"},
    }
    assert compute_direct_bases(fs) == [
        ("A", "B"),
        ("A", "C"),
        ("B", "D"),
        ("C", "D"),
    ]


def test_compute_direct_bases_two_incomparable_bases():
    """A descendant with two incomparable direct bases yields both edges.

    W ⊇ Y and W ⊇ Z with Y ∥ Z, so both (Y,W) and (Z,W) are covers, while the
    transitive shortcut (X,W) must be filtered out by the cover check. The
    assertions below constrain the returned edge list only (asserting that the
    fixture's own sets are incomparable would be set theory, not production
    behaviour, and could never fail).
    """
    fs = {
        "X": {"a"},
        "Y": {"a", "b"},
        "Z": {"a", "c"},
        "W": {"a", "b", "c"},
    }
    edges = compute_direct_bases(fs)

    assert edges == [("X", "Y"), ("X", "Z"), ("Y", "W"), ("Z", "W")]
    # X ⊂ W holds but is *not* a cover: Y and Z sit strictly in between.
    assert ("X", "W") not in edges
    # Both incomparable bases are present exactly once each.
    assert [b for b, d in edges if d == "W"] == ["Y", "Z"]


# ---------------------------------------------------------------------------
# transitive_ancestors
# ---------------------------------------------------------------------------


def test_transitive_ancestors_diamond_dag():
    """Transitive closure over a diamond DAG."""
    edges = [("A", "B"), ("A", "C"), ("B", "D"), ("C", "D")]
    anc = transitive_ancestors(edges)
    assert anc["A"] == set()
    assert anc["B"] == {"A"}
    assert anc["C"] == {"A"}
    assert anc["D"] == {"A", "B", "C"}


def test_transitive_ancestors_chain_is_transitive():
    """An ancestor reached only through an intermediate is still included."""
    edges = [("A", "B"), ("B", "C")]
    anc = transitive_ancestors(edges)
    assert anc["C"] == {"A", "B"}  # A is transitive (no direct edge into C)
    assert anc["B"] == {"A"}
    assert anc["A"] == set()


# ---------------------------------------------------------------------------
# gains
# ---------------------------------------------------------------------------


def test_gain_computation():
    """shared/delta/ratio on a known direct-base pair."""
    fs = {
        "A": {"1", "2", "3"},
        "B": {"1", "2", "3", "4", "5"},
    }
    report = analyze_layer_sharing(fs)
    assert report.gains[("A", "B")] == EdgeGain(shared=3, delta=2, ratio=0.6)


# ---------------------------------------------------------------------------
# _prefix_flag (topological-order prefix check)
# ---------------------------------------------------------------------------


def test_prefix_flag_yes_for_matching_order_and_reorder_needed_otherwise(monkeypatch):
    """The prefix flag is decided by comparing the two topological orders.

    ``features`` are faked so the check itself is what is under test: with the
    canonical order ``1 -> 2`` the base's order is an exact prefix of the
    descendant's (``yes``); with the reversed order it is not
    (``reorder needed``).
    """
    fs = {"A": {"1"}, "B": {"1", "2"}}

    monkeypatch.setattr(
        layersharing,
        "topological_sort_features",
        lambda features_dir, feats: [f for f in ("1", "2") if f in feats],
    )
    matching = analyze_layer_sharing(fs, features_dir=Path("features"))
    assert matching.prefix_flags[("A", "B")] == "yes"

    monkeypatch.setattr(
        layersharing,
        "topological_sort_features",
        lambda features_dir, feats: [f for f in ("2", "1") if f in feats],
    )
    diverging = analyze_layer_sharing(fs, features_dir=Path("features"))
    assert diverging.prefix_flags[("A", "B")] == "reorder needed"


def test_prefix_flag_is_not_applicable_without_features_dir_or_on_error(monkeypatch):
    """``n/a`` both when the check is skipped and when the sort raises."""
    fs = {"A": {"1"}, "B": {"1", "2"}}

    no_dir = analyze_layer_sharing(fs)
    assert no_dir.prefix_flags[("A", "B")] == "n/a"

    def boom(features_dir, feats):
        raise RuntimeError("dependency cycle")

    monkeypatch.setattr(layersharing, "topological_sort_features", boom)
    failing = analyze_layer_sharing(fs, features_dir=Path("features"))
    assert failing.prefix_flags[("A", "B")] == "n/a"


# ---------------------------------------------------------------------------
# Mermaid rendering: id sanitisation, edge de-duplication
# ---------------------------------------------------------------------------


def test_sanitize_id_and_mermaid_node_declarations():
    """Profile names become Mermaid ids; the original name stays the label."""
    assert sanitize_id("lang-java-25") == "lang_java_25"
    assert sanitize_id("a.b/c") == "a_b_c"
    # "_" is part of the legal alphabet and must survive untouched.
    assert sanitize_id("keep__underscore") == "keep__underscore"

    fs = {"base-app": {"1"}, "leaf-app": {"1", "2"}}
    md = render_markdown(analyze_layer_sharing(fs))
    assert 'base_app["base-app"]' in md
    assert 'leaf_app["leaf-app"]' in md
    assert "base_app --> leaf_app" in md


def test_render_markdown_dedups_mermaid_edges_colliding_after_sanitization():
    """``a-b`` and ``a_b`` map to the same node id, so one arrow is enough."""
    fs = {"p": {"1"}, "a-b": {"1", "2"}, "a_b": {"1", "3"}}
    report = analyze_layer_sharing(fs)
    assert report.edges == [("p", "a-b"), ("p", "a_b")]

    md = render_markdown(report)
    assert md.count("p --> a_b") == 1


# ---------------------------------------------------------------------------
# render_markdown: table ordering, chains, recommendations, warnings
# ---------------------------------------------------------------------------


def test_render_markdown_sections_and_warning():
    """render_markdown emits all 5 sections + the ⚠️ multi-base warning."""
    fs = {
        "A": {"1"},
        "B": {"1", "2"},
        "C": {"1", "3"},
        "D": {"1", "2", "3"},
    }
    report = analyze_layer_sharing(fs)
    md = render_markdown(report)

    assert "# Solen Layer-Sharing Analysis" in md
    assert "## Direct FROM relationships" in md
    assert "## FROM chains (direct + transitive)" in md
    assert "## Recommended parent: declarations" in md
    assert "## Ancestor DAG (Mermaid)" in md

    # D has two incomparable direct bases (B and C) -> warning present
    assert "⚠️" in md
    assert "D has multiple incomparable bases" in md

    # Mermaid block present
    assert "```mermaid" in md
    assert "flowchart LR" in md


def test_render_markdown_relationship_rows_sorted_by_shared_descending():
    """The direct-FROM table orders edges by descending shared count.

    Row payloads are asserted verbatim, so the shared/delta/ratio columns and
    the percentage formatting are pinned as well.
    """
    fs = {"A": {"1"}, "B": {"1", "2"}, "C": {"1", "2", "3"}}
    md = render_markdown(analyze_layer_sharing(fs))

    # (B,C) shares 2 of 3 features; (A,B) shares 1 of 2.
    assert "| C | B | 2 | 1 | 66.7% | n/a |" in md
    assert "| B | A | 1 | 1 | 50.0% | n/a |" in md
    assert md.index("| C | B |") < md.index("| B | A |")


def test_render_markdown_chains_and_recommendations_carry_real_metrics():
    """Chain lines and recommendation bullets report the computed numbers."""
    fs = {
        "A": {"1"},
        "B": {"1", "2"},
        "C": {"1", "3"},
        "D": {"1", "2", "3"},
    }
    md = render_markdown(analyze_layer_sharing(fs))

    assert "- D  —  direct base(s): B, C;  full chain: D -> C -> A" in md
    assert "- C  —  direct base(s): A;  full chain: C -> A" in md
    assert "- Add `parent: C` to profile `D` (reuses 2 features, adds 1)." in md
    # Header counts come from the analysed profiles, not from a constant.
    assert "4 profiles, 3 features." in md


def test_representative_chain_prefers_largest_direct_base():
    """The chain walks to the closest ancestor, tie-broken by profile name."""
    # Unequal bases: C (4 features) must win over B (2 features).
    fs = {
        "A": {"1"},
        "B": {"1", "2"},
        "C": {"1", "3", "4", "5"},
        "D": {"1", "2", "3", "4", "5"},
    }
    md = render_markdown(analyze_layer_sharing(fs))
    assert "full chain: D -> C -> A" in md

    # Equal-size bases: deterministic alphabetical tie-break picks C.
    tie = {"A": {"1"}, "B": {"1", "2"}, "C": {"1", "3"}, "D": {"1", "2", "3"}}
    assert "full chain: D -> C -> A" in render_markdown(analyze_layer_sharing(tie))


def test_render_markdown_empty_dag_prints_placeholders():
    """With no subset relation at all, both "no data" placeholders are emitted."""
    fs = {
        "P": {"1"},
        "Q": {"2"},
    }
    report = analyze_layer_sharing(fs)
    assert report.edges == []

    md = render_markdown(report)
    assert "_(no profile has an ancestor)_" in md
    assert "_(no direct-base relationships found)_" in md
    assert "2 profiles, 2 features." in md
    assert "```mermaid" in md
    assert "flowchart LR" in md


def test_render_markdown_single_base_chain_omits_multi_base_warning():
    """A chain emits every recommendation and no ⚠️ warning.

    The fixture has real direct-base relationships, so the recommendation loop
    genuinely iterates and the ``len(bases) > 1`` branch is evaluated and
    correctly not taken. (Asserting "no warning" over an *empty* loop would
    hold regardless of the branch's condition and prove nothing.)
    """
    fs = {"A": {"1"}, "B": {"1", "2"}, "C": {"1", "2", "3"}}
    md = render_markdown(analyze_layer_sharing(fs))

    # Loop body executed: one bullet per edge.
    assert "- Add `parent: A` to profile `B` (reuses 1 features, adds 1)." in md
    assert "- Add `parent: B` to profile `C` (reuses 2 features, adds 1)." in md
    assert "_(no direct-base relationships found)_" not in md

    # Single-base descendants must not trigger the multi-base warning.
    assert "⚠️" not in md
    assert "has multiple incomparable bases" not in md


# ---------------------------------------------------------------------------
# CLI: empty profile set must not silently "succeed"
# ---------------------------------------------------------------------------


def test_cli_layer_sharing_rejects_empty_profile_set(tmp_path):
    """``analyze layer-sharing`` fails loudly when no profile can be collected.

    ``tmp_path`` has neither ``generated/profiles`` nor ``profiles``, so
    ``collect_profile_features`` returns ``{}``. That degenerate input used to
    exit 0 and write a vacuous "0 profiles, 0 features" report; it must instead
    be a user-facing error that produces no artifact.
    """
    report = tmp_path / "layer-sharing.md"
    result = CliRunner().invoke(
        cli,
        ["--repo-root", str(tmp_path), "analyze", "layer-sharing", "--output", str(report)],
    )

    assert result.exit_code == 1, result.output
    assert "No profiles found" in result.stderr
    assert "Analyzed" not in result.output
    assert not report.exists()
