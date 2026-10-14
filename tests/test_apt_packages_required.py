"""Guards for the apt required/optional split in system-essentials.

Background (the defect this pins down): ``features/system-essentials/install.sh``
originally installed ``inputs/apt-packages/base`` as ONE tolerant apt
transaction (``|| true``), because a single unavailable package aborts the whole
transaction. That tolerance was necessary (one arch-unavailable *optional*
package must not break every profile) but blunt: it also meant a missing
**required** package vanished from every published image with a green build,
because ``apt_install`` retries 3x and ``return``s 1
(scripts/lib/features.sh:207-216) and the caller discarded it.

The fix is two-fold:

  * the **required** and **optional** sets are now installed as two independent
    ``|| true``-guarded transactions, so an unresolvable *optional* package can
    no longer abort the shared transaction and starve the required set;
  * a post-install assertion over ``base.required`` bounds the tolerance -- if a
    genuinely required package is still missing after its own transaction, the
    build fails loudly.

These tests therefore enforce:

  * the three list files cannot drift (a partition, no overlap, no phantom);
  * the reconciliation between ``base.required`` and the baked
    ``postInstallCheck`` in feature.json (optional tools must not be asserted);
  * the installer really splits required/optional into two transactions and
    keeps a single union install only on the legacy (no ``base.required``) path;
  * the assertion block itself really fails on a missing required package and
    really passes otherwise -- executed as bash against a stubbed ``dpkg-query``
    and ``uname`` (macOS has neither dpkg tool, so both are stubbed here);
  * an optional-only failure does NOT abort the required transaction (the whole
    point of the split), exercised end-to-end against a stubbed ``apt_install``.
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
        "libpng16-16t64",
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
    # Anti-goal: the legacy (no base.required) path keeps the single tolerant
    # union install verbatim, and the apt contract in scripts/lib/features.sh is
    # untouched -- so a missing base.required must NOT change behaviour.
    assert "apt_install $PKGS || true" in text, "the legacy union install must remain one tolerant transaction"
    assert "apt-get install -y --no-install-recommends $PKGS || true" in text
    # The loud part is the post-condition over the required subset.
    assert BEGIN in text and END in text, "assertion block missing"
    assert 'REQUIRED_LIST="${APT_LIST}.required"' in text
    assert "dpkg-query" in text and "install ok installed" in text
    assert "base.optional" in text, "failure message must name the demotion remedy"


def test_installer_splits_required_and_optional_transactions():
    """Change B: required and optional are two independent `|| true` transactions.

    The union install must NOT be the primary path when base.required is
    present; instead required is installed first (its own transaction) so an
    optional-only failure cannot abort it. `base` remains the source of truth:
    the optional set is derived as union-minus-required, not read from
    base.optional.
    """
    text = INSTALL_SH.read_text(encoding="utf-8")
    assert "REQ_PKGS" in text and "OPT_PKGS" in text, "required/optional sets must be derived"
    assert 'REQUIRED_SRC="${APT_LIST}.required"' in text, "required must be read from the .required list"
    # Each set is installed in its own guarded transaction (tolerance preserved).
    assert "apt_install $REQ_PKGS || true" in text, "required must be its own tolerant transaction"
    assert "apt_install $OPT_PKGS || true" in text, "optional must be a separate tolerant transaction"
    # Optional is derived from the union, so base stays the single source of truth.
    assert "for name in $PKGS" in text, "optional set must be derived as union-minus-required"
    # The split is gated on the required list existing, so legacy is unaffected.
    assert '[ -f "$REQUIRED_SRC" ]' in text, "split must be conditional on base.required existing"


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


# --------------------------------------------------------------------------- #
# End-to-end proof of the required/optional transaction SPLIT (Change B).
# apt_install is stubbed with real apt's all-or-nothing semantics: a single
# unresolvable package aborts the whole invocation. This is what makes the
# split observable -- under one union transaction an optional-only failure
# takes the required set down with it; under two transactions it cannot.
# --------------------------------------------------------------------------- #
def _run_install_and_assert(tmp_path: Path, *, union_line: str, required_lines: str, unresolvable: str):
    """Run install.sh's install+assert region against a stub apt.

    Returns (CompletedProcess, set_of_packages_actually_installed).
    """
    stub = tmp_path / "stub"
    stub.mkdir(exist_ok=True)
    installed = tmp_path / "installed.txt"
    installed.write_text("", encoding="utf-8")
    stubs = {
        "uname": "#!/bin/bash\necho Linux\n",
        "apt_install": (
            "#!/bin/bash\n"
            'for a in "$@"; do\n'
            "  for u in $SOL_TEST_UNRESOLVABLE; do\n"
            '    [ "$a" = "$u" ] && { echo "apt_install: E: Unable to locate package $a" >&2; exit 100; }\n'
            "  done\n"
            "done\n"
            'for a in "$@"; do echo "$a" >> "$SOL_TEST_INSTALLED_FILE"; done\n'
        ),
        "dpkg-query": (
            "#!/bin/bash\n"
            'pkg="${@: -1}"\n'
            '[ -f "$SOL_TEST_INSTALLED_FILE" ] && grep -qx "$pkg" "$SOL_TEST_INSTALLED_FILE" '
            '&& { echo "install ok installed"; exit 0; }\n'
            'echo "unknown ok not-installed"\n'
        ),
    }
    for name, body in stubs.items():
        p = stub / name
        p.write_text(body, encoding="utf-8")
        p.chmod(0o755)

    (tmp_path / "base").write_text(union_line + "\n", encoding="utf-8")
    (tmp_path / "base.required").write_text(required_lines + "\n", encoding="utf-8")
    (tmp_path / "base.optional").write_text("# derived at runtime from union-minus-required\n", encoding="utf-8")

    text = INSTALL_SH.read_text(encoding="utf-8")
    start = 'echo "system-essentials: installing packages listed in ${APT_LIST} (if present)"'
    region = text.split(start, 1)[1].split(END, 1)[0]
    script = tmp_path / "region.sh"
    script.write_text(
        "set -euo pipefail\n"
        f'APT_LIST="{tmp_path}/base"\n'
        f"{region}\n"
        'echo "SURVIVED-PAST-ASSERTION"\n',
        encoding="utf-8",
    )
    proc = subprocess.run(
        ["/bin/bash", str(script)],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
        env={
            "PATH": f"{stub}:/usr/bin:/bin",
            "SOL_TEST_UNRESOLVABLE": unresolvable,
            "SOL_TEST_INSTALLED_FILE": str(installed),
        },
    )
    return proc, set(installed.read_text(encoding="utf-8").split())


def test_optional_only_failure_does_not_abort_required_transaction(tmp_path):
    """The point of Change B.

    ``solen-bogus-optional`` sits in the union list (``base``) but NOT in
    ``base.required``. It is unresolvable, so the *optional* transaction aborts
    -- yet because the required set is installed in its OWN prior transaction,
    jq/rsync still land and the required assertion still passes (rc == 0).
    Under the old single union install this exact input aborted everything and
    the assertion exited 1, failing every profile.
    """
    proc, got = _run_install_and_assert(
        tmp_path,
        union_line="jq rsync solen-bogus-optional",
        required_lines="jq\nrsync\n",
        unresolvable="solen-bogus-optional",
    )
    assert proc.returncode == 0, (
        f"an optional-only failure must NOT abort the required transaction: "
        f"rc={proc.returncode} err={proc.stderr!r}"
    )
    assert {"jq", "rsync"} <= got, f"required packages must still be installed, got {sorted(got)}"
    assert "solen-bogus-optional" not in got, "the unresolvable optional must not be recorded as installed"
    assert "required packages verified present" in proc.stdout
    assert "SURVIVED-PAST-ASSERTION" in proc.stdout


def test_missing_required_package_still_fails_after_the_split(tmp_path):
    """Regression guard: the split must not weaken the assertion.

    When a genuinely required package is unresolvable, its own transaction
    aborts, it stays missing, and the assertion still exits 1.
    """
    proc, got = _run_install_and_assert(
        tmp_path,
        union_line="jq rsync tmux",
        required_lines="jq\nsolen-bogus-required\n",
        unresolvable="solen-bogus-required",
    )
    assert proc.returncode == 1, f"a missing required package must still fail: rc={proc.returncode} out={proc.stdout!r}"
    assert "solen-bogus-required" in proc.stderr, "must name the missing required package"
    assert "SURVIVED-PAST-ASSERTION" not in proc.stdout
    # The optional transaction is independent: `rsync`/`tmux` are not required
    # here, so they install fine even though the required transaction aborted.
    assert {"rsync", "tmux"} <= got, f"optional transaction must proceed independently, got {sorted(got)}"
