"""Guards for the apt required/optional split in system-essentials.

Background (the defect this pins down): ``features/system-essentials/install.sh``
installs ``inputs/apt-packages/base`` as ONE tolerant apt transaction
(``|| true``), because a single unavailable package aborts the whole
transaction -- so making the install fatal would let one arch-unavailable
*optional* package break every profile. ``apt_install`` retries 3x and
``return``s 1 (scripts/lib/features.sh:207-216) and the caller discarded it,
which meant a missing **required** package vanished from every published image
with a green build. The fix bounds the tolerance with a post-install assertion
over ``base.required`` only.

These tests therefore enforce three things:

  * the three list files cannot drift (a partition, no overlap, no phantom);
  * the reconciliation between ``base.required`` and the baked
    ``postInstallCheck`` in feature.json (optional tools must not be asserted);
  * the assertion block itself really fails on a missing required package and
    really passes otherwise -- executed as bash against a stubbed ``dpkg-query``
    and ``uname`` (macOS has neither dpkg tool, so both are stubbed here).
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
APT_DIR = REPO / "inputs" / "apt-packages"
BASE = APT_DIR / "base"
REQUIRED = APT_DIR / "base.required"
OPTIONAL = APT_DIR / "base.optional"
INSTALL_SH = REPO / "features" / "system-essentials" / "install.sh"
FEATURE_JSON = REPO / "features" / "system-essentials" / "feature.json"

BEGIN = "# --- begin required-package assertion ---"
END = "# --- end required-package assertion ---"

# neovim ships the `nvim` binary; everything else is named after its package.
_BINARY_ALIAS = {"neovim": "nvim"}


def _names(path: Path) -> list[str]:
    """Package names in an apt list file (comments/blank lines stripped)."""
    out: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        out.extend(stripped.split())
    return out


def _binary(pkg: str) -> str:
    return _BINARY_ALIAS.get(pkg, pkg)


# --------------------------------------------------------------------------- #
# List-file reconciliation (no drift possible between the three files)
# --------------------------------------------------------------------------- #
def test_required_and_optional_partition_the_union_list():
    base, required, optional = set(_names(BASE)), set(_names(REQUIRED)), set(_names(OPTIONAL))
    assert base, f"{BASE} parsed empty"
    assert required and optional, "both subsets must be non-empty (an all-required list is blanket-loud)"
    assert required | optional == base, (
        f"base.required ∪ base.optional must equal base; "
        f"missing={sorted(base - (required | optional))} "
        f"phantom={sorted((required | optional) - base)}"
    )
    assert required & optional == set(), f"a package cannot be both required and optional: {sorted(required & optional)}"


def test_union_list_keeps_the_packages_other_consumers_expect():
    # The union list is deliberately NOT modified by the split (identical apt
    # transaction, identical layer bytes for every profile). Anchor a few names
    # so an accidental deletion is caught here rather than in a built image.
    base = set(_names(BASE))
    for pkg in ("jq", "rsync", "cmake", "pkg-config", "fzf", "tmux", "neovim", "fonts-dejavu-core"):
        assert pkg in base, f"{pkg} disappeared from the union list {BASE}"


def test_executable_essentials_are_required():
    required = set(_names(REQUIRED))
    # `rsync` is the regression anchor: it survived only by luck (an upgrade
    # over an existing version) and would otherwise have silently disappeared.
    for pkg in ("jq", "rsync", "cmake", "pkg-config"):
        assert pkg in required, f"{pkg} must stay required"


def test_tex_runtime_libraries_are_required():
    # Comment in the union list: XeTeX/XeLaTeX needs these at TinyTeX install time.
    required = set(_names(REQUIRED))
    for pkg in (
        "libfontconfig1",
        "libfreetype6",
        "libx11-6",
        "libxrender1",
        "libxext6",
        "libxft2",
        "libpng16-16",
        "libxcb1",
        "fonts-dejavu-core",
    ):
        assert pkg in required, f"{pkg} must stay required"


def test_interactive_tools_are_optional_only():
    required, optional = set(_names(REQUIRED)), set(_names(OPTIONAL))
    for pkg in ("fzf", "tmux", "neovim"):
        assert pkg in optional, f"{pkg} is a convenience tool, expected optional"
        assert pkg not in required, f"{pkg} must not be required: no build step consumes it"


# --------------------------------------------------------------------------- #
# The installer keeps the tolerant install AND the bounded assertion
# --------------------------------------------------------------------------- #
def test_installer_stays_tolerant_but_asserts_required():
    text = INSTALL_SH.read_text(encoding="utf-8")
    # Anti-goal: the single apt transaction over the unchanged union list stays
    # non-fatal, and the apt contract in scripts/lib/features.sh is untouched.
    assert "apt_install $PKGS || true" in text, "the union install must remain one tolerant transaction"
    assert "apt-get install -y --no-install-recommends $PKGS || true" in text
    # The loud part is the post-condition over the required subset.
    assert BEGIN in text and END in text, "assertion block missing"
    assert 'REQUIRED_LIST="${APT_LIST}.required"' in text
    assert "dpkg-query" in text and "install ok installed" in text
    assert "base.optional" in text, "failure message must name the demotion remedy"


def test_assertion_block_avoids_bash4_constructs():
    # Host harnesses source these scripts under macOS bash 3.2. Only executable
    # lines count -- the block's own comments mention the constructs it avoids.
    block = INSTALL_SH.read_text(encoding="utf-8").split(BEGIN, 1)[1].split(END, 1)[0]
    code = "\n".join(l for l in block.splitlines() if not l.strip().startswith("#"))
    assert "mapfile" not in code
    assert ",,}" not in code, "${VAR,,} is bash 4+; use case/`tr` instead"


def test_post_install_check_does_not_assert_optional_packages():
    """The baked check and the required list must agree (the reconciliation).

    Asserting an optional tool there would make "optional" meaningless: its
    absence would still fail the build, just later and with a worse message.
    """
    cmd = json.loads(FEATURE_JSON.read_text(encoding="utf-8"))["postInstallCheck"]["command"]
    tokens = set(cmd.split())
    optional = set(_names(OPTIONAL))
    required = set(_names(REQUIRED))
    for pkg in optional:
        assert _binary(pkg) not in tokens, (
            f"postInstallCheck asserts {_binary(pkg)} ({pkg}) but {pkg} is optional; "
            f"either promote it to {REQUIRED.name} or drop it from the check"
        )
    # Symmetrically, the required executables that the check can express stay.
    for pkg in ("jq", "cmake", "rsync"):
        assert pkg in required and _binary(pkg) in tokens, f"{pkg} must be required AND asserted"


# --------------------------------------------------------------------------- #
# Executable proof of the assertion logic (dpkg-query and uname are stubbed:
# neither exists on macOS, so the block cannot be exercised against dpkg here)
# --------------------------------------------------------------------------- #
def _run_block(tmp_path: Path, required_lines: str, installed: str, union_line: str):
    stub = tmp_path / "stub"
    stub.mkdir(exist_ok=True)
    for name, body in (
        ("uname", "#!/bin/bash\necho Linux\n"),
        (
            "dpkg-query",
            (
                '#!/bin/bash\npkg="${@: -1}"\n'
                'for i in $SOL_TEST_INSTALLED; do [ "$i" = "$pkg" ] && { echo "install ok installed"; exit 0; }; done\n'
                'echo "unknown"\nexit 0\n'
            ),
        ),
    ):
        p = stub / name
        p.write_text(body, encoding="utf-8")
        p.chmod(0o755)

    (tmp_path / "base").write_text(union_line + "\n", encoding="utf-8")
    (tmp_path / "base.required").write_text(required_lines + "\n", encoding="utf-8")
    (tmp_path / "base.optional").write_text("# nothing\n", encoding="utf-8")

    block = INSTALL_SH.read_text(encoding="utf-8").split(BEGIN, 1)[1].split(END, 1)[0]
    script = tmp_path / "block.sh"
    script.write_text(
        "set -euo pipefail\n"
        f'APT_LIST="{tmp_path}/base"\n'
        f"{block}\n"
        'echo "SURVIVED-PAST-ASSERTION"\n',
        encoding="utf-8",
    )
    # /usr/bin:/bin here is for grep/tr only; no package manager lives there.
    return subprocess.run(
        ["/bin/bash", str(script)],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
        env={"PATH": f"{stub}:/usr/bin:/bin", "SOL_TEST_INSTALLED": installed},
    )


def test_assertion_fails_loudly_for_a_missing_required_package(tmp_path):
    proc = _run_block(
        tmp_path,
        required_lines="jq\nsolen-definitely-not-a-real-package\n",
        installed="jq",
        union_line="jq solen-definitely-not-a-real-package tmux",
    )
    assert proc.returncode == 1, f"expected failure, got rc={proc.returncode} out={proc.stdout!r}"
    assert "FAILED" in proc.stderr
    assert "solen-definitely-not-a-real-package" in proc.stderr, "must name the missing package"
    assert "base.required" in proc.stderr, "must name the file to edit"
    assert "base.optional" in proc.stderr and "demote" in proc.stderr.lower(), "must give the remedy"
    assert "ONE apt transaction" in proc.stderr, "must state the partial-transaction hazard"
    # Both misses are reported together (not fail-fast on the first one).
    assert proc.stderr.count("solen-definitely-not-a-real-package") >= 1
    assert "SURVIVED-PAST-ASSERTION" not in proc.stdout


def test_assertion_passes_when_every_required_package_is_present(tmp_path):
    proc = _run_block(
        tmp_path,
        required_lines="jq\nrsync\n",
        installed="jq rsync tmux",
        union_line="jq rsync tmux",
    )
    assert proc.returncode == 0, f"unexpected failure rc={proc.returncode} err={proc.stderr!r}"
    assert "required packages verified present" in proc.stdout
    assert "SURVIVED-PAST-ASSERTION" in proc.stdout


def test_assertion_is_skipped_off_linux(tmp_path):
    """Host-side safety: sourcing/running the block without Linux+dpkg must not fail."""
    stub = tmp_path / "stub"
    stub.mkdir()
    p = stub / "uname"
    p.write_text("#!/bin/bash\necho Darwin\n", encoding="utf-8")
    p.chmod(0o755)
    (tmp_path / "base").write_text("jq\n", encoding="utf-8")
    (tmp_path / "base.required").write_text("solen-not-real\n", encoding="utf-8")
    block = INSTALL_SH.read_text(encoding="utf-8").split(BEGIN, 1)[1].split(END, 1)[0]
    script = tmp_path / "block.sh"
    script.write_text(
        f'set -euo pipefail\nAPT_LIST="{tmp_path}/base"\n{block}\necho SKIPPED-OK\n', encoding="utf-8"
    )
    proc = subprocess.run(
        ["/bin/bash", str(script)],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
        env={"PATH": f"{stub}:/usr/bin:/bin"},
    )
    assert proc.returncode == 0, proc.stderr
    assert "SKIPPED-OK" in proc.stdout
