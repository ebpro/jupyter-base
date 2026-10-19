"""Non-vacuity contract for the scripts/utils/inject_prebaked_helpers.sh guard.

DEFECT MECHANISM (measured, not asserted). The pre-fix guard was an unanchored
substring test::

    if grep -qE "FEATURE_HELPERS_DIR|feature_helpers.sh|helpers.sh" "$inst"

The needle ``helpers.sh`` is a substring of *other* helper-library names that
feature installers legitimately reference without containing the prebaked
sourcing payload the guard is supposed to detect:

* ``source "/usr/local/lib/download-release-helpers.sh"``  (a different lib)
* comments mentioning ``features/_lib/fh_helpers.sh``      (prose, not sourcing)

``features/tilt/install.sh`` is exactly that shape: no FEATURE_HELPERS_DIR
payload anywhere, yet the substring match made the old guard print
"- ok (already sources helpers)" and skip injection forever -- silently
(exit 0). TestFalsePositiveRedProof drives the real tilt bytes through the
pinned old script and shows the wrong skip, then through the fixed script and
shows the injection.

The fixed guard counts two ANCHORED sentinels instead:
  marker  = '^# Auto-inserted by scripts/inject_prebaked_helpers.sh$'
  payload = a real 'source "${FEATURE_HELPERS_DIR}/helpers.sh"' line
and maps the states:
  payload>=1, marker<=1  -> skip (injected OR hand-written, e.g. features/gh)
  marker==0, payload==0  -> inject
  marker>=2              -> contradictory stacked injection -> exit 1 loud
  marker>=1, payload==0  -> marker without payload (tampered) -> exit 1 loud

"payload present, marker absent" is deliberately NOT an error: features/gh and
features/quarto-common are hand-written in that state and must keep skipping.

SECOND, MASKING DEFECT fixed in the same file. The pre-move ROOT arithmetic
(``dirname $0`` + one ``/..``) resolves to ``scripts/`` from the script's
current ``scripts/utils/`` home, so FEATURES_DIR pointed at the nonexistent
``scripts/features`` and every run silently scanned nothing and exited 0 --
which is also why the substring bug could not fire in practice until now.
The fix re-anchors ROOT two levels up and refuses to run when FEATURES_DIR
is absent (TestMissingFeaturesDir).

RED proof convention (repo law, see test_container_tools_are_mirrored.py and
test_java_sdkman_postinstall_check.py): the old script is fetched from the
pinned BASELINE_SHA -- never HEAD -- the pinned blob is asserted to still
contain the buggy pattern, and the old-vs-current blobs are asserted
distinct so this file can never self-reference its own fix.
"""

import hashlib
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
SCRIPT_REL = "scripts/utils/inject_prebaked_helpers.sh"

#: Commit recorded at the start of the fix task: its script blob still holds
#: the unanchored substring guard. Pinned, never HEAD (self-annihilating red
#: proofs were the defect class fixed in 90e8db8).
BASELINE_SHA = "4aaf22d"

CURRENT_SCRIPT = (REPO / SCRIPT_REL).read_text(encoding="utf-8")

MARKER = "# Auto-inserted by scripts/inject_prebaked_helpers.sh"
PAYLOAD_SOURCE_LINE = 'source "${FEATURE_HELPERS_DIR}/helpers.sh"'
OLD_NEEDLE = 'grep -qE "FEATURE_HELPERS_DIR|feature_helpers.sh|helpers.sh"'


def _resolve_bash4() -> str:
    """bash >= 4 (macOS /bin/bash is 3.2; the image shell is modern bash)."""
    for candidate in ("/opt/homebrew/bin/bash", "/usr/local/bin/bash", "/bin/bash"):
        if not Path(candidate).exists():
            continue
        probe = subprocess.run(
            [candidate, "-c", 'echo "${BASH_VERSINFO[0]}"'],
            capture_output=True,
            text=True,
            check=False,
        )
        if probe.returncode == 0 and probe.stdout.strip().isdigit() and int(probe.stdout.strip()) >= 4:
            return candidate
    return ""


BASH = _resolve_bash4()
requires_bash = pytest.mark.skipif(not BASH, reason="no bash >= 4 found")


def _baseline_script() -> str:
    proc = subprocess.run(
        ["git", "-C", str(REPO), "show", f"{BASELINE_SHA}:{SCRIPT_REL}"],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        pytest.skip(f"baseline {BASELINE_SHA} not reachable in this clone (shallow?)")
    old = proc.stdout
    assert OLD_NEEDLE in old, (
        f"baseline {BASELINE_SHA} no longer holds the unanchored substring guard "
        f"-- re-pin BASELINE_SHA before trusting the RED proofs in this file"
    )
    assert old != CURRENT_SCRIPT, "RED proof would be self-referential (old == current script)"
    return old


def _make_tree(tmp_path: Path, features: dict) -> Path:
    """Fixture repo root with features/<name>/install.sh from literal content."""
    root = tmp_path
    for name, content in features.items():
        d = root / "features" / name
        d.mkdir(parents=True, exist_ok=True)
        (d / "install.sh").write_text(content, encoding="utf-8")
        (d / "install.sh").chmod(0o755)
    return root


def _place(root: Path, script_text: str, layout: str) -> Path:
    """Install the script under test into the fixture tree.

    layout="utils": root/scripts/utils/ (the real repo location; only the
    FIXED script resolves FEATURES_DIR correctly from here).
    layout="flat":  root/scripts/        (the pre-move location; where the
    BASELINE script's ROOT math works, so its guard logic -- and only that --
    is what the RED proofs exercise).
    """
    rel = {"utils": "scripts/utils", "flat": "scripts"}[layout]
    p = root / rel / "inject_prebaked_helpers.sh"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(script_text, encoding="utf-8")
    p.chmod(0o755)
    return p


def _run(script: Path) -> subprocess.CompletedProcess:
    return subprocess.run([BASH, str(script)], capture_output=True, text=True, timeout=60, check=False)


def _manifest(root: Path) -> dict:
    """relpath -> sha256 of bytes, for every install.sh in the fixture tree."""
    return {
        str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted(root.glob("features/*/install.sh"))
    }


# Faithful false-positive input: the REAL tilt installer. It sources only
# /usr/local/lib/download-release-helpers.sh (line 9/11) and mentions
# features/_lib/fh_helpers.sh in a comment (line 39) -- both carry the
# "helpers.sh" substring, neither is the prebaked payload.
TILT_REAL = (REPO / "features" / "tilt" / "install.sh").read_text(encoding="utf-8")
GH_REAL = (REPO / "features" / "gh" / "install.sh").read_text(encoding="utf-8")
PYTHON_CONDA_REAL = (REPO / "features" / "python-conda" / "install.sh").read_text(encoding="utf-8")


class TestScriptShapePinned:
    """Static drift guards on the shipped bytes."""

    def test_baseline_anchor_is_not_self_referential(self):
        old = _baseline_script()
        assert old != CURRENT_SCRIPT

    def test_unanchored_substring_needle_is_gone(self):
        assert OLD_NEEDLE not in CURRENT_SCRIPT, (
            "the unanchored helpers.sh substring test is back -- it matches "
            "download-release-helpers.sh / fh_helpers.sh and wrongly skips "
            "never-injected installers (the tilt defect)"
        )

    def test_guard_is_anchored_on_both_sentinels(self):
        assert "^# Auto-inserted by scripts/inject_prebaked_helpers[.]sh$" in CURRENT_SCRIPT
        assert "[$][{]FEATURE_HELPERS_DIR[}]/helpers[.]sh" in CURRENT_SCRIPT

    def test_ambiguous_state_exits_nonzero(self):
        assert "contradictory helpers-injection state" in CURRENT_SCRIPT


@requires_bash
class TestFalsePositiveRedProof:
    """The old guard wrongly skips the real tilt file; the new one injects."""

    def test_old_guard_skips_tilt_which_has_no_payload(self, tmp_path):
        assert PAYLOAD_SOURCE_LINE not in TILT_REAL, (
            "tilt no longer demonstrates the false positive (payload appeared?) -- re-derive the fixture"
        )
        root = _make_tree(tmp_path, {"tilt": TILT_REAL})
        script = _place(root, _baseline_script(), "flat")
        result = _run(script)
        assert result.returncode == 0, result
        assert "already sources helpers" in result.stdout, (
            "old guard unexpectedly stopped mis-skipping -- harness premise broke"
        )
        assert "injecting" not in result.stdout
        assert (root / "features/tilt/install.sh").read_text(encoding="utf-8") == TILT_REAL, (
            "old guard unexpectedly injected -- the mis-skip is the defect, not the fix"
        )

    def test_new_guard_injects_the_same_file(self, tmp_path):
        root = _make_tree(tmp_path, {"tilt": TILT_REAL})
        script = _place(root, CURRENT_SCRIPT, "utils")
        result = _run(script)
        assert result.returncode == 0, result
        assert "injecting" in result.stdout
        after = (root / "features/tilt/install.sh").read_text(encoding="utf-8")
        assert after != TILT_REAL
        assert after.startswith(MARKER)
        assert PAYLOAD_SOURCE_LINE in after
        assert after.endswith(TILT_REAL), "original content must be preserved verbatim below the payload"

    def test_substring_only_input_is_still_injected(self, tmp_path):
        # Minimal synthetic twin of the tilt mechanism: the needle appears
        # ONLY inside another library name and a comment.
        content = (
            "#!/usr/bin/env bash\n"
            'if [ -f "/usr/local/lib/download-release-helpers.sh" ]; then\n'
            '  source "/usr/local/lib/download-release-helpers.sh"\n'
            "fi\n"
            "# see features/_lib/fh_helpers.sh for the hook design\n"
        )
        root = _make_tree(tmp_path, {"synth": content})
        script = _place(root, CURRENT_SCRIPT, "utils")
        result = _run(script)
        assert result.returncode == 0, result
        assert "injecting" in result.stdout


@requires_bash
class TestIdempotence:
    """Two consecutive runs must produce byte-identical trees."""

    def test_second_run_changes_nothing(self, tmp_path):
        root = _make_tree(tmp_path, {"tilt": TILT_REAL, "gh": GH_REAL})
        script = _place(root, CURRENT_SCRIPT, "utils")
        first = _run(script)
        assert first.returncode == 0, first
        manifest_1 = _manifest(root)
        second = _run(script)
        assert second.returncode == 0, second
        manifest_2 = _manifest(root)
        assert manifest_1 == manifest_2, "re-running the injector mutated the tree (not idempotent)"
        assert "injecting" not in second.stdout
        assert (root / "features/tilt/install.sh").read_text(encoding="utf-8").count(MARKER) == 1

    def test_old_guard_is_idempotent_only_because_it_over_skips(self, tmp_path):
        # The old script was "idempotent" on already-injected files only by
        # over-matching; the new guard keeps that property via the payload
        # sentinel instead. (Duplicate-injection was nonetheless achieved
        # historically: features/python-conda ships 2 markers -- pinned below.)
        root = _make_tree(tmp_path, {"condaprema": PYTHON_CONDA_REAL})
        script = _place(root, _baseline_script(), "flat")
        result = _run(script)
        assert result.returncode == 0, result
        assert (root / "features/condaprema/install.sh").read_text(encoding="utf-8") == PYTHON_CONDA_REAL


@requires_bash
class TestContradictoryStatesFailLoud:
    """Ambiguous guard state must exit nonzero, never silently skip."""

    def test_marker_without_payload_fails(self, tmp_path):
        content = f"{MARKER}\n#!/usr/bin/env bash\necho hi\n"
        root = _make_tree(tmp_path, {"tampered": content})
        script = _place(root, CURRENT_SCRIPT, "utils")
        result = _run(script)
        assert result.returncode != 0, "marker-without-payload was silently tolerated"
        assert "contradictory helpers-injection state" in result.stderr
        assert (root / "features/tampered/install.sh").read_text(encoding="utf-8") == content, (
            "the failing run must not mutate the contradictory file"
        )

    def test_stacked_markers_fail(self, tmp_path):
        # The real python-conda shape: two auto-insert markers, one payload.
        assert PYTHON_CONDA_REAL.count(MARKER) == 2, (
            "python-conda no longer carries the historical double injection -- update this fixture"
        )
        root = _make_tree(tmp_path, {"python-conda": PYTHON_CONDA_REAL})
        script = _place(root, CURRENT_SCRIPT, "utils")
        result = _run(script)
        assert result.returncode != 0, "stacked markers were silently tolerated"
        assert "contradictory helpers-injection state" in result.stderr
        assert "2 marker(s)" in result.stderr

    def test_hand_written_payload_without_marker_skips_cleanly(self, tmp_path):
        # gh is payload-present/marker-absent BY HAND and is a healthy state:
        # it must skip with exit 0, not fail (failing here would break the
        # tool on the real tree).
        assert MARKER not in GH_REAL
        assert PAYLOAD_SOURCE_LINE in GH_REAL
        root = _make_tree(tmp_path, {"gh": GH_REAL})
        script = _place(root, CURRENT_SCRIPT, "utils")
        result = _run(script)
        assert result.returncode == 0, result
        assert "already sources prebaked helpers" in result.stdout
        assert (root / "features/gh/install.sh").read_text(encoding="utf-8") == GH_REAL


@requires_bash
class TestMissingFeaturesDir:
    """The masking path bug: a wrong FEATURES_DIR must be loud, not a silent no-op."""

    def test_old_script_silently_noops_from_repo_layout(self, tmp_path):
        root = _make_tree(tmp_path, {"tilt": TILT_REAL})
        script = _place(root, _baseline_script(), "utils")  # real repo layout
        result = _run(script)
        assert result.returncode == 0, (
            "old script unexpectedly loud from scripts/utils/ -- re-check the masking-defect premise"
        )
        assert "Injected helpers into 0" in result.stdout
        assert (root / "features/tilt/install.sh").read_text(encoding="utf-8") == TILT_REAL

    def test_new_script_finds_features_from_repo_layout(self, tmp_path):
        root = _make_tree(tmp_path, {"tilt": TILT_REAL})
        script = _place(root, CURRENT_SCRIPT, "utils")
        result = _run(script)
        assert result.returncode == 0, result
        assert "injecting" in result.stdout, (
            "ROOT re-anchor regressed: the script no longer resolves features/ from scripts/utils/"
        )

    def test_new_script_refuses_missing_features_dir(self, tmp_path):
        root = tmp_path  # no features/ at all
        script = _place(root, CURRENT_SCRIPT, "utils")
        result = _run(script)
        assert result.returncode != 0
        assert "features directory not found" in result.stderr
