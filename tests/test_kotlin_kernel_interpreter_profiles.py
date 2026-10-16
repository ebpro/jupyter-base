"""Static regression: every profile that requests the kotlin kernel must
have a resolvable interpreter for the kernelspec registration.

Regression target (introduced by cc31f65): ``lang-kotlin`` sets
``INSTALL_KOTLIN_KERNEL: true``, but its feature closure contains no
``python-conda`` — ``expand_feature_dependencies`` proves it — while the
installer at that revision could only use the miniforge python and exited 1
without it. ``lang-kotlin`` with the kernel gate on was therefore
unbuildable. The fix (features/kotlin/install.sh) resolves ``python3`` on
PATH when the conda interpreter is absent and fails closed when neither
exists.

Invariant enforced here, per kernel-requesting matrix profile: either the
expanded closure provides ``python-conda`` (the conda interpreter), or the
installer still ships the ``python3`` fallback branch. A future change that
reintroduces a conda-only installer would turn every conda-less
kernel profile red here — before it silently breaks a published build.

Pure file inspection: no network, no docker, no subprocess.
"""

from pathlib import Path

import pytest
import yaml

from solen.core.feature import expand_feature_dependencies

REPO = Path(__file__).resolve().parent.parent
FEATURES = REPO / "features"
MATRIX_DIR = REPO / "profiles" / "matrix"
INSTALL_SH = FEATURES / "kotlin" / "install.sh"


def _kernel_requesting_profiles():
    """(matrix file, profile name, feature list) for every matrix entry with
    INSTALL_KOTLIN_KERNEL: true."""
    found = []
    for path in sorted(MATRIX_DIR.glob("*.yaml")):
        data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        matrix = data.get("matrix") or {}
        for name, entry in matrix.items():
            options = (entry or {}).get("options") or {}
            gate = options.get("INSTALL_KOTLIN_KERNEL")
            if gate is True or (isinstance(gate, str) and gate.lower() == "true"):
                found.append((path, name, list((entry or {}).get("features") or [])))
    return found


KERNEL_PROFILES = _kernel_requesting_profiles()


def test_at_least_one_matrix_profile_requests_the_kernel():
    """Guard against the parametrisation silently emptying (e.g. by a key
    rename): lang-kotlin must remain a kernel consumer."""
    names = {name for _, name, _ in KERNEL_PROFILES}
    assert "lang-kotlin" in names, f"expected lang-kotlin among kernel consumers, got {names}"


@pytest.mark.parametrize(
    "matrix_file,profile,features",
    KERNEL_PROFILES,
    ids=[f"{p}" for _, p, _ in KERNEL_PROFILES],
)
def test_kernel_profile_has_a_resolvable_interpreter(matrix_file, profile, features):
    closure = expand_feature_dependencies(FEATURES, features)
    if "python-conda" in closure:
        return  # conda interpreter is present in the closure; nothing to prove

    source = INSTALL_SH.read_text(encoding="utf-8")
    assert "command -v python3" in source, (
        f"profile {profile!r} ({matrix_file.name}) sets INSTALL_KOTLIN_KERNEL=true "
        f"but its expanded closure {sorted(closure)} contains no python-conda: the "
        "kotlin installer must keep the python3-on-PATH fallback branch, or this "
        "profile cannot register the kernelspec at all (cc31f65 regression)."
    )
    assert "refusing to proceed without one" in source, (
        "the fallback branch must stay fail-closed: with neither conda python "
        "nor python3 available, the installer has to exit non-zero, never skip."
    )
