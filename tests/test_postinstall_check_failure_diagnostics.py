"""The generated post-install check runner must print the failing command + exit code.

Motivation: the check loop in ``/opt/solen/run-postinstall-checks.sh`` used to
swallow the check's exit status and print only ``FAIL postInstallCheck: <feature>``,
so a red check carried zero evidence about *which* command failed or with *what*
code. These tests render the REAL template over a minimal profile dict, extract
the generated runner heredoc, replace the ``source
/opt/solen/_lib/run-check-as-user.sh`` line with a deterministic stub, and
EXECUTE the loop under bash. Pass/fail gating (``exit "$failed"``) is asserted
UNCHANGED; only the diagnostic line is newly required.

Non-vacuity / RED proof: against the pre-change template the failure output
contains neither the exit code nor the decoded command, so
``test_failing_check_prints_command_and_exit_code`` and
``test_exit_code_is_not_a_constant`` fail (verified via ``git stash`` of the
template before the edit was committed).
"""

import base64
import re
import subprocess
from pathlib import Path

from solen.generators.dockerfile_gen import render_template

_REPO_ROOT = Path(__file__).resolve().parents[1]

#: Two checks, distinct ids/commands, so per-check attribution is observable.
_CHECKS = [
    ("alpha", "alpha --version"),
    ("beta", "beta-tool do-check --json"),
]


def _profile_dict(checks):
    """A minimal profile dict in exactly the shape ``build_profile_data`` returns.

    The template only consumes: name, from_stage, features_str, provides_str,
    env, checks[].id, checks[].command_b64, install_features.
    """
    ids = [fid for fid, _cmd in checks]
    return {
        "name": "diagtest",
        "features": ids,
        "features_str": " ".join(ids),
        "provides_str": "",
        "env": {},
        "checks": [
            {
                "id": fid,
                "command": cmd,
                "command_b64": base64.b64encode(cmd.encode("utf-8")).decode("ascii"),
            }
            for fid, cmd in checks
        ],
        "install_features": ids,
        "from_stage": "base",
        "parent": None,
    }


def _extract_runner_script(text):
    """Heredoc body of /opt/solen/run-postinstall-checks.sh from the Dockerfile text."""
    marker = "cat > /opt/solen/run-postinstall-checks.sh <<'SCRIPT'\n"
    assert marker in text, "generated runner heredoc not found in rendered Dockerfile"
    start = text.index(marker) + len(marker)
    end = text.index("\nSCRIPT\n", start)
    return text[start:end] + "\n"


def _run_runner(tmp_path, checks, stub_body):
    """Render the real template, extract the runner, stub run_check_as_user, execute.

    ``stub_body`` is the shell body of the stub ``run_check_as_user``; ``$1``
    is the decoded check command, exactly as the real wrapper receives it.
    """
    (tmp_path / "solen-cli").symlink_to(_REPO_ROOT / "solen-cli")
    text = render_template(tmp_path, [_profile_dict(checks)])
    script = _extract_runner_script(text).replace(
        "source /opt/solen/_lib/run-check-as-user.sh",
        f"run_check_as_user() {{ {stub_body}; }}",
    )
    runner = tmp_path / "runner.sh"
    runner.write_text(script, encoding="utf-8")
    return subprocess.run(
        ["bash", str(runner)],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,  # returncode is asserted explicitly by each test
    )


def test_failing_check_prints_command_and_exit_code(tmp_path):
    """A check failing with exit 3 must surface `exit 3` AND the decoded command."""
    proc = _run_runner(
        tmp_path,
        _CHECKS,
        'case "$1" in *"beta-tool"*) return 3 ;; *) return 0 ;; esac',
    )
    # Gating semantics unchanged: the runner exits with the failed-check count.
    assert proc.returncode == 1, proc.stdout + proc.stderr
    assert "FAIL postInstallCheck: beta" in proc.stderr
    # The new diagnostics (the point of this task):
    assert re.search(r"exit\s+3", proc.stderr), (
        "failing check must print its non-zero exit code; stderr was: " + proc.stderr
    )
    assert "beta-tool do-check --json" in proc.stderr, (
        "failing check must print the decoded command; stderr was: " + proc.stderr
    )
    # A passing check emits no failure text, and the summary is unchanged.
    assert "FAIL postInstallCheck: alpha" not in proc.stderr
    assert "OK postInstallCheck: alpha" in proc.stdout
    assert "1/2 passed" in proc.stdout


def test_exit_code_is_not_a_constant(tmp_path):
    """The printed code is the check's real status (7 prints 7, not a fixed value)."""
    proc = _run_runner(tmp_path, [("gamma", "gamma-verify --strict")], "return 7")
    assert proc.returncode == 1, proc.stdout + proc.stderr
    assert re.search(r"exit\s+7", proc.stderr), proc.stderr
    assert "gamma-verify --strict" in proc.stderr
    assert "FAIL postInstallCheck: gamma" in proc.stderr


def test_passing_checks_emit_no_failure_text(tmp_path):
    """All-green: no FAIL anywhere, exit 0 — identical to pre-change behaviour."""
    proc = _run_runner(tmp_path, _CHECKS, "return 0")
    assert proc.returncode == 0, proc.stdout + proc.stderr
    combined = proc.stdout + proc.stderr
    assert "FAIL" not in combined
    assert "OK postInstallCheck: alpha" in proc.stdout
    assert "OK postInstallCheck: beta" in proc.stdout
    assert "2/2 passed" in proc.stdout
