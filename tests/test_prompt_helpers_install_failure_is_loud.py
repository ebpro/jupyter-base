"""Loud-failure contract for ``features/prompt-helpers/install.sh``.

Historically the script degraded silently in two places:

1.  The archive-fallback awk expression (``/gitstatusd$|gitstatus$/``) could
    never match the real tarball member names, which carry an architecture
    suffix (``gitstatusd-linux-aarch64``, ``gitstatusd-linux-x86_64``).  The
    fallback therefore extracted nothing and the script moved on.
2.  When ``gitstatusd`` was still missing after the fallback, the script only
    printed a warning and exited 0.  Builds on the declared platforms
    (``linux/amd64``, ``linux/arm64`` from ``feature.json``) silently shipped
    without the binary.

These tests pin the loud-failure contract against the *real* script text
(sliced, never retyped) and run it hermetically with a stubbed ``uname`` and
``find`` so the platform and the archive search are controlled.  The pre-fix
form is re-run from commit ``3147a48`` via ``git show`` to document the silent
pass it used to produce (the regression being fixed).
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
INSTALL_SH = REPO_ROOT / "features" / "prompt-helpers" / "install.sh"

# Commit whose install.sh still had the silent form (echo-only terminal check
# plus the arch-suffix-blind awk expression).
OLD_FORM_REF = "3147a48"

# Real member names of the gitstatus v1.5.4 release tarballs.
MEMBER_AARCH64 = "gitstatusd-linux-aarch64"
MEMBER_X86_64 = "gitstatusd-linux-x86_64"

# Anchor that opens the slice covering the fallback and the terminal check.
SLICE_ANCHOR = 'TARGET_DIR="${HOME_DIR}/.local/share/gitstatus"'

AWK_PROG_RE = re.compile(r"awk -F\"/\" '([^']+)'")


def _bash() -> str:
    """Pick a bash >= 4 (the script uses arrays plus ``set -u``)."""
    for cand in ("/opt/homebrew/bin/bash", "/usr/local/bin/bash", "/bin/bash"):
        path = Path(cand)
        if not path.is_file():
            continue
        out = subprocess.run(
            [cand, "-c", 'printf "%s" "${BASH_VERSINFO[0]}"'],
            capture_output=True,
            text=True,
            check=False,
        )
        if out.stdout.strip().isdigit() and int(out.stdout.strip()) >= 4:
            return cand
    raise RuntimeError("no bash >= 4 available")


def _read_install_sh(ref: str | None = None) -> str:
    if ref is None:
        return INSTALL_SH.read_text()
    out = subprocess.run(
        ["git", "show", f"{ref}:features/prompt-helpers/install.sh"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    assert out.returncode == 0, f"git show {ref} failed: {out.stderr}"
    return out.stdout


def _slice(text: str) -> str:
    idx = text.find(SLICE_ANCHOR)
    assert idx >= 0, f"slice anchor not found: {SLICE_ANCHOR}"
    line_start = text.rfind("\n", 0, idx) + 1
    return text[line_start:]


def _make_stub_bin(sandbox: Path, bash: str) -> None:
    stub = sandbox / "bin"
    stub.mkdir()
    uname = stub / "uname"
    uname.write_text(
        "#!" + bash + "\n"
        'case "$1" in\n'
        '  -s) echo "${STUB_OS:-Linux}" ;;\n'
        '  -m) echo "${STUB_ARCH:-x86_64}" ;;\n'
        '  *)  echo "${STUB_OS:-Linux}" ;;\n'
        "esac\n"
    )
    uname.chmod(0o755)
    find = stub / "find"
    find.write_text("#!" + bash + "\nexit 0\n")
    find.chmod(0o755)
    for tool in ("tar", "mktemp", "mv", "cp", "rm", "ln", "chmod", "mkdir", "awk"):
        src = shutil.which(tool)
        assert src, f"host tool missing: {tool}"
        (stub / tool).symlink_to(src)


def _run_slice(
    script: str, sandbox: Path, bash: str, os_name: str, arch: str
) -> subprocess.CompletedProcess:
    (sandbox / "slice.sh").write_text("set -euo pipefail\n" + script)
    home = sandbox / "home"
    home.mkdir()
    env = dict(os.environ)
    env.update(
        HOME_DIR=str(home),
        STUB_OS=os_name,
        STUB_ARCH=arch,
        PATH=str(sandbox / "bin"),
    )
    return subprocess.run(
        [bash, str(sandbox / "slice.sh")],
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )


def _run_current_slice(
    sandbox: Path, bash: str, os_name: str, arch: str
) -> subprocess.CompletedProcess:
    return _run_slice(_slice(_read_install_sh()), sandbox, bash, os_name, arch)


def test_fallback_awk_matches_real_tarball_member_names():
    """The fallback awk must match the arch-suffixed real member names."""
    m = AWK_PROG_RE.search(_read_install_sh())
    assert m, "archive-fallback awk expression not found in install.sh"
    prog = m.group(1)
    for member in (MEMBER_AARCH64, MEMBER_X86_64):
        out = subprocess.run(
            ["awk", "-F", "/", prog],
            input=member + "\n",
            capture_output=True,
            text=True,
            check=False,
        )
        assert out.returncode == 0, f"awk failed: {out.stderr}"
        assert out.stdout.strip() == member, (
            f"awk program {prog!r} must match real member {member!r}, "
            f"got {out.stdout.strip()!r}"
        )


def test_missing_gitstatusd_fails_loudly_on_declared_linux_platforms():
    """No gitstatusd on a declared platform (feature.json) => non-zero exit."""
    bash = _bash()
    for os_name, arch in (("Linux", "x86_64"), ("Linux", "aarch64")):
        with tempfile.TemporaryDirectory() as td:
            sandbox = Path(td)
            _make_stub_bin(sandbox, bash)
            proc = _run_current_slice(sandbox, bash, os_name, arch)
        combined = proc.stdout + proc.stderr
        assert proc.returncode != 0, (
            f"install.sh must fail on {os_name}/{arch} when gitstatusd is "
            f"missing after the fallback; got rc=0\n{combined}"
        )
        assert "gitstatusd" in combined


def test_missing_gitstatusd_skips_gracefully_off_platform():
    """No gitstatusd on an undeclared platform => warning, exit 0."""
    bash = _bash()
    with tempfile.TemporaryDirectory() as td:
        sandbox = Path(td)
        _make_stub_bin(sandbox, bash)
        proc = _run_current_slice(sandbox, bash, "Darwin", "arm64")
    assert proc.returncode == 0, (
        f"undeclared platform must skip gracefully, got rc={proc.returncode}\n"
        f"{proc.stdout}\n{proc.stderr}"
    )
    assert "gitstatusd" in proc.stdout


def test_probe_curl_is_resilient_to_transient_egress_failures():
    """The upstream probe must not treat a transient failure as unavailable."""
    content = _read_install_sh()
    lines = [ln for ln in content.splitlines() if "curl" in ln and "probe_url" in ln]
    assert lines, "probe curl line not found in install.sh"
    line = lines[0]
    for flag in ("--max-time", "--retry", "--retry-all-errors"):
        assert flag in line, f"probe curl must carry {flag}: {line}"


def test_old_form_silently_passed_on_linux():
    """Characterization: the pre-fix form exited 0 with only a warning."""
    bash = _bash()
    with tempfile.TemporaryDirectory() as td:
        sandbox = Path(td)
        _make_stub_bin(sandbox, bash)
        proc = _run_slice(
            _slice(_read_install_sh(OLD_FORM_REF)), sandbox, bash, "Linux", "x86_64"
        )
    assert proc.returncode == 0, (
        "pre-fix form should have silently exited 0 "
        f"(got rc={proc.returncode})\n{proc.stdout}\n{proc.stderr}"
    )
    assert "❌" in proc.stdout
