"""Regression tests for boolean option gates in features/kotlin/install.sh.

Profile options declared as YAML booleans are stringified through ``str()``
by the generator (``True`` -> ``"True"``), so an installer that compares the
received ENV value case-sensitively against a lowercase literal silently
skips installation (lang-kotlin shipped without the Kotlin compiler).

These tests extract the *actual* defaulting, normalisation and gate lines
from install.sh and evaluate only those in bash — the installer body is
never executed, so the test has no side effects and needs no container.
"""

import re
import shutil
import subprocess
from pathlib import Path

import pytest

INSTALL_SH = Path(__file__).resolve().parent.parent / "features" / "kotlin" / "install.sh"

# The installer runs on Linux images with bash >= 4 (AGENTS.md: "All Bash 4+"),
# and the normalisation under test uses ${VAR,,} (bash 4+ only). macOS ships
# /bin/bash 3.2, so resolve a bash >= 4 explicitly instead of relying on PATH.
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

# Fail LOUDLY rather than skipping quietly if no usable bash exists, unless
# bash 4+ is genuinely absent — then the skip reason enumerates candidates.
if not BASH:
    _versions = {c: (_bash_major(c) if Path(c).is_file() else "missing") for c in _CANDIDATES}
    pytest.skip(
        f"No bash >= 4 found among candidates (name: version): {_versions}; "
        "installer normalisation requires bash 4 (${VAR,,})",
        allow_module_level=True,
    )


def _extract_gate_lines(source: str) -> str:
    """Pull defaulting, normalisation and `if ... = "true"` gate lines from the script."""
    lines = [
        line
        for line in source.splitlines()
        if re.match(
            r'^(INSTALL_KOTLIN(_KERNEL)?=\$\{|INSTALL_KOTLIN(_KERNEL)?_LC="\$\{?'
            r'|if \[ "\$?\{?INSTALL_KOTLIN(_KERNEL)?(_LC)?\}?" = "(true|True)" \]; then$)',
            line,
        )
    ]
    # Replace each `if <gate>; then` with an echo of the branch decision and
    # a `fi`, keeping the script valid without the installer body.
    out: list[str] = ["set -euo pipefail"]
    for line in lines:
        m = re.match(r'^if \[ "\$\{?(\w+)\}?" = "(\w+)" \]; then$', line)
        if m:
            var, literal = m.group(1), m.group(2)
            out.append(f'if [ "${{{var}}}" = "{literal}" ]; then echo "GATE[{var}] ENTER"; else echo "GATE[{var}] SKIP"; fi')
        else:
            out.append(line)
    return "\n".join(out) + "\n"


def _evaluate(env: dict[str, str]) -> str:
    script = _extract_gate_lines(INSTALL_SH.read_text(encoding="utf-8"))
    proc = subprocess.run(
        [BASH, "-c", script],
        check=False,
        capture_output=True,
        text=True,
        timeout=15,
        env={"PATH": "/usr/bin:/bin", **env},
    )
    assert proc.returncode == 0, f"gate snippet failed: {proc.stderr}"
    return proc.stdout


def test_resolved_bash_supports_lowercase_expansion() -> None:
    """Pin the harness interpreter: the resolved bash must be >= 4 (loudly, not skipped)."""
    version = subprocess.run(
        [BASH, "--version"], capture_output=True, text=True, check=True
    ).stdout.splitlines()[0]
    print(f"\nresolved bash: {BASH} -> {version}")
    assert _bash_major(BASH) >= 4
    # The exact construct used by install.sh must work in this interpreter.
    probe = subprocess.run(
        [BASH, "-c", 'v="True"; [ "${v,,}" = "true" ] && echo OK'],
        capture_output=True,
        text=True,
        check=True,
    )
    assert probe.stdout.strip() == "OK"


def test_gate_extraction_found_the_real_comparisons() -> None:
    """Guard against the regex silently matching nothing (a test that cannot fail)."""
    source = INSTALL_SH.read_text(encoding="utf-8")
    snippet = _extract_gate_lines(source)
    assert 'INSTALL_KOTLIN=${INSTALL_KOTLIN:-true}' in snippet
    assert 'INSTALL_KOTLIN_KERNEL=${INSTALL_KOTLIN_KERNEL:-false}' in snippet
    assert snippet.count("] ENTER") == 2, "expected exactly the two boolean gates"


@pytest.mark.parametrize("value", ["true", "True", "TRUE"])
def test_compiler_gate_enters_for_all_truthy_spellings(value: str) -> None:
    out = _evaluate({"INSTALL_KOTLIN": value})
    assert "GATE[INSTALL_KOTLIN_LC] ENTER" in out, (
        f"compiler gate skipped for value {value!r} (str(True) regression): {out!r}"
    )


@pytest.mark.parametrize("value", ["true", "True", "TRUE"])
def test_kernel_gate_enters_for_all_truthy_spellings(value: str) -> None:
    out = _evaluate({"INSTALL_KOTLIN_KERNEL": value})
    assert "GATE[INSTALL_KOTLIN_KERNEL_LC] ENTER" in out, (
        f"kernel gate skipped for value {value!r} (str(True) regression): {out!r}"
    )


@pytest.mark.parametrize("value", ["false", "False", "FALSE"])
def test_gates_skip_for_all_falsy_spellings(value: str) -> None:
    out = _evaluate({"INSTALL_KOTLIN": value, "INSTALL_KOTLIN_KERNEL": value})
    assert "GATE[INSTALL_KOTLIN_LC] SKIP" in out
    assert "GATE[INSTALL_KOTLIN_KERNEL_LC] SKIP" in out


def test_defaults_unchanged_when_unset() -> None:
    """Defaulting semantics of the pre-fix lines are preserved: compiler=true, kernel=false."""
    out = _evaluate({})
    assert "GATE[INSTALL_KOTLIN_LC] ENTER" in out
    assert "GATE[INSTALL_KOTLIN_KERNEL_LC] SKIP" in out


def test_normalisation_survives_set_u() -> None:
    """The normalised variables must never be unbound under `set -u` (a79ce85 guards)."""
    out = _evaluate({"INSTALL_KOTLIN": "True"})
    assert "unbound variable" not in out
