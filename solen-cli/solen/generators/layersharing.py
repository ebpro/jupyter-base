"""Layer-sharing analysis: the FROM-layer sharing DAG over profile feature sets.

Computes, from each profile's expanded (leaf) feature set, the subset/cover
poset of profiles and renders a Markdown report describing which profiles could
share Docker build layers via chained ``FROM`` stages.

The functions here are pure (no I/O) so they can be unit-tested against small
in-memory feature-set dicts. The CLI (see :mod:`solen.cli`, ``analyze
layer-sharing``) is the only place that collects profile features from disk and
writes the report file.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from solen.core.feature import topological_sort_features


def sanitize_id(name: str) -> str:
    """Sanitize a profile name into a Mermaid-safe node id.

    Mirrors the ``[A-Za-z0-9_]`` sanitization used by
    ``scripts/utils/generate_mermaid.py``.
    """
    return re.sub(r"[^0-9A-Za-z_]+", "_", name)


@dataclass
class EdgeGain:
    """Shared/delta/ratio metrics for a single direct-base edge ``(base, desc)``."""

    shared: int
    delta: int
    ratio: float


@dataclass
class LayerSharingReport:
    """Result of :func:`analyze_layer_sharing`."""

    feature_sets: dict[str, set[str]]
    edges: list[tuple[str, str]]  # (base, descendant) cover edges
    ancestors: dict[str, set[str]]  # profile -> full set of ancestors
    gains: dict[tuple[str, str], EdgeGain]  # (base, descendant) -> metrics
    prefix_flags: dict[tuple[str, str], str]  # (base, desc) -> yes|reorder needed|n/a


def compute_direct_bases(feature_sets: dict[str, set[str]]) -> list[tuple[str, str]]:
    """Compute the cover (direct base) edges of the profile subset poset.

    A profile ``A`` is a *direct base* of profile ``B`` iff ``F[A]`` is a proper
    subset of ``F[B]`` and there is no third profile ``C`` with
    ``F[A] < F[C] < F[B]``. In poset terms, ``B`` covers ``A``. A profile may
    have several incomparable direct bases.

    Returns a list of ``(base, descendant)`` tuples, sorted for determinism.
    """
    names = list(feature_sets)
    edges: list[tuple[str, str]] = []
    for base in names:
        f_base = feature_sets[base]
        for desc in names:
            if base == desc:
                continue
            f_desc = feature_sets[desc]
            if not f_base < f_desc:
                continue
            covered = any(
                f_base < feature_sets[c] < f_desc
                for c in names
                if c != base and c != desc
            )
            if not covered:
                edges.append((base, desc))
    edges.sort()
    return edges


def transitive_ancestors(edges: list[tuple[str, str]]) -> dict[str, set[str]]:
    """Compute the transitive closure of ancestors for every node in ``edges``.

    ``edges`` are ``(base, descendant)`` pairs (a base is an ancestor of its
    descendant). Returns ``profile -> set(all ancestors)`` where the set
    includes both direct bases and bases reached through one or more
    intermediates. Profiles that appear only as bases (roots) map to an empty
    set.
    """
    direct_bases: dict[str, set[str]] = {}
    nodes: set[str] = set()
    for base, desc in edges:
        direct_bases.setdefault(desc, set()).add(base)
        nodes.add(base)
        nodes.add(desc)

    result: dict[str, set[str]] = {}
    for node in nodes:
        ancestors: set[str] = set()
        stack = list(direct_bases.get(node, ()))
        while stack:
            current = stack.pop()
            if current in ancestors:
                continue
            ancestors.add(current)
            stack.extend(direct_bases.get(current, ()))
        result[node] = ancestors
    return result


def _prefix_flag(
    features_dir: Path | None,
    base: str,
    desc: str,
    feature_sets: dict[str, set[str]],
) -> str:
    """Return ``yes`` if base's topological order is an exact prefix of desc's.

    ``reorder needed`` when the orders differ, ``n/a`` when the check cannot be
    performed (no ``features_dir`` or the topological sort fails).
    """
    if features_dir is None:
        return "n/a"
    try:
        order_base = topological_sort_features(features_dir, sorted(feature_sets[base]))
        order_desc = topological_sort_features(features_dir, sorted(feature_sets[desc]))
    except Exception:
        return "n/a"
    return "yes" if order_desc[: len(order_base)] == order_base else "reorder needed"


def _representative_chain(
    start: str,
    feature_sets: dict[str, set[str]],
    direct_bases: dict[str, set[str]],
) -> list[str]:
    """Follow one representative FROM chain from ``start`` down to a root.

    At each step picks the direct base with the largest feature set (the
    maximal proper subset, i.e. the closest ``FROM`` candidate), so the result
    reads as ``descendant -> base -> ... -> root``. Deterministic: ties are
    broken by profile name.
    """
    chain = [start]
    current = start
    seen = {current}
    while True:
        bases = direct_bases.get(current, ())
        if not bases:
            break
        next_node = max(sorted(bases), key=lambda b: (len(feature_sets[b]), b))
        if next_node in seen:
            break
        chain.append(next_node)
        seen.add(next_node)
        current = next_node
    return chain


def analyze_layer_sharing(
    feature_sets: dict[str, set[str]],
    features_dir: Path | None = None,
) -> LayerSharingReport:
    """Analyze FROM-layer sharing across profiles.

    ``feature_sets`` maps profile name -> expanded (leaf) feature set. When
    ``features_dir`` is provided, the optional topological prefix check is
    computed for each direct-base edge.
    """
    edges = compute_direct_bases(feature_sets)
    ancestors = transitive_ancestors(edges)

    gains: dict[tuple[str, str], EdgeGain] = {}
    prefix_flags: dict[tuple[str, str], str] = {}
    for base, desc in edges:
        f_base = feature_sets[base]
        f_desc = feature_sets[desc]
        shared = len(f_base)
        delta = len(f_desc - f_base)
        ratio = (shared / len(f_desc)) if f_desc else 0.0
        gains[(base, desc)] = EdgeGain(shared=shared, delta=delta, ratio=ratio)
        prefix_flags[(base, desc)] = _prefix_flag(features_dir, base, desc, feature_sets)

    return LayerSharingReport(
        feature_sets=feature_sets,
        edges=edges,
        ancestors=ancestors,
        gains=gains,
        prefix_flags=prefix_flags,
    )


def render_markdown(report: LayerSharingReport) -> str:
    """Render a Markdown report from a :class:`LayerSharingReport`."""
    n_profiles = len(report.feature_sets)
    union: set[str] = set()
    for feats in report.feature_sets.values():
        union |= feats
    m_features = len(union)

    # Direct bases per descendant, reused by the chains + recommendations.
    direct_bases: dict[str, set[str]] = {}
    for base, desc in report.edges:
        direct_bases.setdefault(desc, set()).add(base)

    lines: list[str] = []

    # 1. header
    lines.append("# Solen Layer-Sharing Analysis")
    lines.append("")
    lines.append(f"{n_profiles} profiles, {m_features} features.")
    lines.append("")

    # 2. direct FROM relationships
    lines.append("## Direct FROM relationships")
    lines.append("")
    lines.append(
        "| Descendant | Direct base (FROM) | Shared | Delta | Share ratio | Usable as ancestor? |"
    )
    lines.append("|---|---|---|---|---|---|")
    sorted_edges = sorted(
        report.edges, key=lambda e: (-report.gains[e].shared, e[1], e[0])
    )
    for base, desc in sorted_edges:
        gain = report.gains[(base, desc)]
        ratio_str = f"{gain.ratio * 100:.1f}%"
        lines.append(
            f"| {desc} | {base} | {gain.shared} | {gain.delta} | {ratio_str} "
            f"| {report.prefix_flags[(base, desc)]} |"
        )
    lines.append("")

    # 3. FROM chains (direct + transitive)
    lines.append("## FROM chains (direct + transitive)")
    lines.append("")
    chain_emitted = False
    for desc in sorted(report.ancestors):
        if not report.ancestors[desc]:
            continue
        chain_emitted = True
        bases = sorted(direct_bases.get(desc, ()))
        chain = _representative_chain(desc, report.feature_sets, direct_bases)
        lines.append(
            f"- {desc}  —  direct base(s): {', '.join(bases)};  "
            f"full chain: {' -> '.join(chain)}"
        )
    if not chain_emitted:
        lines.append("_(no profile has an ancestor)_")
    lines.append("")

    # 4. recommended parent declarations
    lines.append("## Recommended parent: declarations")
    lines.append("")
    if direct_bases:
        for desc in sorted(direct_bases):
            bases = sorted(direct_bases[desc])
            for base in bases:
                gain = report.gains[(base, desc)]
                lines.append(
                    f"- Add `parent: {base}` to profile `{desc}` "
                    f"(reuses {gain.shared} features, adds {gain.delta})."
                )
            if len(bases) > 1:
                lines.append(
                    f"  - ⚠️ {desc} has multiple incomparable bases "
                    f"({', '.join(bases)}) — a single `parent:` cannot share all of "
                    f"them; consider a combined base profile."
                )
    else:
        lines.append("_(no direct-base relationships found)_")
    lines.append("")

    # 5. ancestor DAG (mermaid)
    lines.append("## Ancestor DAG (Mermaid)")
    lines.append("")
    lines.append("```mermaid")
    lines.append("flowchart LR")
    nodes: dict[str, str] = {}
    for base, desc in report.edges:
        nodes[sanitize_id(base)] = base
        nodes[sanitize_id(desc)] = desc
    for nid in sorted(nodes):
        lines.append(f'{nid}["{nodes[nid]}"]')
    seen_edges: set[tuple[str, str]] = set()
    for base, desc in report.edges:
        a = sanitize_id(base)
        b = sanitize_id(desc)
        if (a, b) in seen_edges:
            continue
        seen_edges.add((a, b))
        lines.append(f"{a} --> {b}")
    lines.append("```")
    lines.append("")

    return "\n".join(lines)
