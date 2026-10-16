"""Interpreter-floor guard for every ``postInstallCheck`` in ``features/*/feature.json``.

Background (the defect this pins down): ``features/pip-requirements/feature.json``
asserted ``python -m pip --version``. On this fleet, bare ``python`` exists on
PATH **only** when ``python-conda`` is baked (conda prepends its env). But
``pip-requirements`` dependsOn only ``python-base``, which provides ``python3``
and never ``python``. Measured ``rc=127`` (``python: command not found``) in
5/5 non-conda images (lang-kotlin, lang-java-db-jdk25, codeserver,
jetbrains-gateway, lang-web-dev) while ``python3 -m pip --version`` returned
``rc=0`` in all of them *and* in conda images. 22 of 31 profiles bake
pip-requirements without conda. Because ``verify-published`` runs the baked
checks as a hard gate (``exit "$failed"``), this one check would have red-gated
every non-conda publish for the rest of the fleet's life.

The enforceable rule is deliberately **not** "never name python".
``python-conda``'s own check (``conda --version && python --version``) and
features that transitively ``dependsOn`` ``python-conda`` (quarto-python,
java-kernel) are *guaranteed* an interpreter called ``python`` by their declared
dependency graph, and renaming those would change green checks for no gain.
The rule is:

    A postInstallCheck may invoke bare ``python`` only if the feature
    transitively dependsOn ``python-conda``.

Any feature without that guarantee must use ``python3``, which is the fleet-wide
interpreter floor (``python-base`` provides it; conda images resolve ``python3``
to the same base interpreter, measured ``rc=0`` in both classes).

The test therefore reconstructs the dependsOn graph from the feature manifests
themselves: if a feature ever drops its conda dependency while keeping a bare
``python`` check, it fails here instead of at publish time.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

FEATURES_DIR = Path("features")

# Bare `python` as a shell word: not part of a longer identifier (ipython,
# python3, python2...), not a path component (/usr/bin/python,
# ${CONDA_DIR}/bin/python — those name an explicit, self-evident binary).
BARE_PYTHON = re.compile(r"(?<![\w./$-])python(?![\w.\-])")


def _load_features() -> dict[str, dict]:
    features: dict[str, dict] = {}
    for feature_json in sorted(FEATURES_DIR.glob("*/feature.json")):
        data = json.loads(feature_json.read_text(encoding="utf-8"))
        feature_id = data.get("id", feature_json.parent.name)
        features[feature_id] = data
    return features


def _conda_closure(feature_id: str, deps: dict[str, list[str]]) -> bool:
    """True if the feature is python-conda itself or transitively dependsOn it (acyclic graph, enforced by the validator)."""
    if feature_id == "python-conda":
        return True  # self-guaranteeing: the feature installs the `python` its check names
    seen: set[str] = set()
    stack = [feature_id]
    while stack:
        for dep in deps.get(stack.pop(), []):
            if dep == "python-conda":
                return True
            if dep not in seen:
                seen.add(dep)
                stack.append(dep)
    return False


FEATURES = _load_features()
DEPS = {fid: (data.get("dependsOn") or []) for fid, data in FEATURES.items()}


@pytest.mark.parametrize("feature_id", sorted(FEATURES))
def test_bare_python_check_requires_conda_dependency(feature_id):
    """A check may name bare `python` only when python-conda guarantees it on PATH."""
    command = (FEATURES[feature_id].get("postInstallCheck") or {}).get("command", "")
    if BARE_PYTHON.search(command) and not _conda_closure(feature_id, DEPS):
        pytest.fail(
            f"features/{feature_id}/feature.json postInstallCheck invokes bare "
            f"`python` but the feature does not (transitively) depend on "
            f"python-conda, so the check dies with rc=127 in every non-conda "
            f"profile. Use `python3` (the fleet-wide interpreter floor). "
            f"Command: {command!r}"
        )


def test_pip_requirements_check_uses_python3():
    """Exact regression pin for the FIX-1 defect: pip-requirements must name python3."""
    command = FEATURES["pip-requirements"]["postInstallCheck"]["command"]
    assert command == "python3 -m pip --version"


def test_conda_dependent_bare_python_users_are_pinned():
    """The features legitimately using bare `python` today must keep a conda guarantee.

    If someone drops python-conda from one of these dependency graphs, the
    parametrized rule above already catches it; this test additionally fails
    loudly if a *new* feature joins the bare-python set, forcing an explicit
    review instead of silent drift.
    """
    bare_users = {
        fid
        for fid, data in FEATURES.items()
        if BARE_PYTHON.search((data.get("postInstallCheck") or {}).get("command", ""))
    }
    assert bare_users == {"python-conda", "quarto-python", "java-kernel"}
    # python-conda is self-guaranteeing; the other two must stay conda-bound.
    for fid in bare_users - {"python-conda"}:
        assert _conda_closure(fid, DEPS), f"{fid} names bare python without a conda dependency"
