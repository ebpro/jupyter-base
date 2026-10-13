"""Regression tests for the kotlin installer's compiler-install failure path.

`sdk install kotlin` is a network-dependent fetch (SDKMAN CDN +
repo1.maven.apache.org). It used to be wrapped in `|| true`, so a failed
install produced a green build whose image had no kotlinc, while
feature.json advertised the compiler via a `kotlinc -version` check.
These tests run the *real* installer body with the `su` and `sdk`
invocations stubbed on PATH and assert:

  * install-command failure -> the installer exits non-zero and names the
    requested version and the network fetch on stderr;
  * install-command success -> stdout is byte-identical to the old
    installer's stdout (behaviour unchanged on the happy path);
  * RED proof: the pre-fix installer (retrieved via `git show` of the
    commit where the masking still existed) exits 0 on the very same
    failing input, so these tests genuinely discriminate the fix.

No container and no network access is required or performed.
"""

import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
INSTALL_SH = REPO / "features" / "kotlin" / "install.sh"

# The last revision whose features/kotlin/install.sh still wrapped the
# `su ... sdk install kotlin` invocation in `|| true`. Pinned to a SHA
# rather than HEAD so the test keeps working after the fix is committed.
OLD_FORM_REF = "7000760"

# The installer requires bash >= 4 (${VAR,,} normalisation); macOS ships
# /bin/bash 3.2, so resolve explicitly the way tests/test_kotlin_boolean_gates.py
# does. Kept local to this module to avoid coupling the two test files.
_CANDIDATES = [
    "/opt/homebrew/bin/bash",
    "/usr/local/bin/bash",
    "/bin/bash",
]


def _bash_major(path: str) -> int:
    out = subprocess.run(
        [path, "-c", 'echo "${BASH_VERSINFO[0]}"'],
        check=False,
        capture_output=True,
        text=True,
        timeout=10,
    )
    try:
        return int(out.stdout.strip())
    except ValueError:
        return 0


def _resolve_bash() -> str:
    found = shutil.which("bash")
    ordered = _CANDIDATES + ([found] if found and found not in _CANDIDATES else [])
    for cand in ordered:
        if Path(cand).is_file() and _bash_major(cand) >= 4:
            return cand
    return ""


BASH = _resolve_bash()

if not BASH:
    _versions = {c: (_bash_major(c) if Path(c).is_file() else "missing") for c in _CANDIDATES}
    pytest.skip(
        f"No bash >= 4 found among candidates (name: version): {_versions}; "
        "the kotlin installer requires bash 4 (${VAR,,})",
        allow_module_level=True,
    )


def _write_stub(path: Path, body: str) -> None:
    path.write_text("#!/usr/bin/env bash\n" + body + "\n", encoding="utf-8")
    path.chmod(0o755)


def _make_sandbox(tmp_path: Path, sdk_exit: int, tag: str) -> tuple[Path, Path]:
    """PATH with a stub `su` (executes the -lc string in a fresh bash) and a
    stub `sdk` (exits with the requested code, echoing its argv to stderr).
    Deliberately no kotlinc anywhere, so the installer takes the install path."""
    root = tmp_path / tag
    root.mkdir(exist_ok=True)
    bin_dir = root / "bin"
    bin_dir.mkdir(exist_ok=True)
    home = root / "home"
    home.mkdir(exist_ok=True)
    _write_stub(
        bin_dir / "su",
        # su - <user> -s /bin/bash -lc "<cmd>": run the last argument, drop
        # the login-shell profile sourcing (irrelevant to error propagation;
        # real su propagates the command's exit status, which is what the
        # installer's handling is tested against).
        f'cmd="${{@: -1}}"\nexec {BASH} -c "$cmd"',
    )
    _write_stub(bin_dir / "sdk", 'echo "sdk-stub: ${0##*/} $*" >&2\nexit ' + str(sdk_exit))
    return bin_dir, home


def _run_installer(
    installer: Path, tmp_path: Path, sdk_exit: int, env_extra: dict[str, str], tag: str = "run"
):
    bin_dir, home = _make_sandbox(tmp_path, sdk_exit, tag)
    env = {"PATH": f"{bin_dir}:/usr/bin:/bin", "HOME": str(home), "INSTALL_KOTLIN": "true"}
    env.update(env_extra)
    return subprocess.run(
        [BASH, str(installer)],
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
        cwd=str(tmp_path),
        check=False,
    )


def _old_form_installer(tmp_path: Path) -> Path:
    proc = subprocess.run(
        ["git", "-C", str(REPO), "show", f"{OLD_FORM_REF}:features/kotlin/install.sh"],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0 or "|| true" not in proc.stdout:
        pytest.skip(f"pre-fix installer not retrievable at {OLD_FORM_REF} (shallow clone?)")
    path = tmp_path / "install_old.sh"
    path.write_text(proc.stdout, encoding="utf-8")
    path.chmod(0o755)
    return path


@pytest.mark.parametrize("kotlin_version", ["1.9.24", None], ids=["pinned", "unpinned"])
def test_compiler_install_failure_exits_nonzero_with_named_cause(tmp_path, kotlin_version):
    extra = {"KOTLIN_VERSION": kotlin_version} if kotlin_version else {}
    proc = _run_installer(INSTALL_SH, tmp_path, sdk_exit=1, env_extra=extra)

    assert proc.returncode != 0, (
        "installer masked a failing `sdk install kotlin` (|| true regression): "
        f"rc={proc.returncode} stderr={proc.stderr!r}"
    )
    assert proc.returncode == 1
    # The loud message goes to stderr and names the cause.
    assert "FAILED" in proc.stderr
    assert "network" in proc.stderr.lower()
    assert "sdk install kotlin" in proc.stderr  # the attempted command
    if kotlin_version:
        assert kotlin_version in proc.stderr  # version requested, named
    else:
        assert "<sdkman current>" in proc.stderr  # explicit about no pin
    # The stub actually ran the composed command (proves both branches compose).
    attempted = f"sdk install kotlin {kotlin_version}" if kotlin_version else "sdk install kotlin"
    assert f"sdk-stub: {attempted}" in proc.stderr
    # Aborted before reaching the kernel stage / completion banner.
    assert "kotlin: done" not in proc.stdout


def test_compiler_install_success_behaviour_unchanged(tmp_path):
    new = _run_installer(INSTALL_SH, tmp_path, sdk_exit=0, env_extra={}, tag="new")
    assert new.returncode == 0, new.stderr
    assert "kotlin: done" in new.stdout
    assert "FAILED" not in new.stderr

    old = _run_installer(
        _old_form_installer(tmp_path), tmp_path, sdk_exit=0, env_extra={}, tag="old"
    )
    assert old.returncode == 0, old.stderr
    # Happy path is byte-identical to the pre-fix installer.
    assert new.stdout == old.stdout


def test_red_proof_old_form_masked_the_failure(tmp_path):
    """The pre-fix installer stayed green on the exact input that now fails."""
    old = _run_installer(_old_form_installer(tmp_path), tmp_path, sdk_exit=1, env_extra={})
    assert old.returncode == 0, (
        f"old form unexpectedly failed (rc={old.returncode}); the discriminating "
        "input no longer discriminates and the new-form test may be vacuous"
    )
    assert "kotlin: done" in old.stdout  # the exact defect: green, no kotlinc
