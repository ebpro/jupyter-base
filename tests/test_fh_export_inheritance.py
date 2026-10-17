"""Regression tests for the exported-helper inheritance defect (CI run 39046605159).

The generated Dockerfile's feature loop (dockerfile_template.j2) sources
`/opt/solen/_lib/helpers.sh` in a parent bash — which sources
`features/_lib/fh_helpers.sh` and ends with its `export -f` line — and then
spawns each installer in a CHILD shell (`bash /tmp/features/<f>/install.sh`).
The child therefore only sees what `export -f` put in the environment.

`fh_resolve_version` calls `_fh_find_versions_json` as its first statement, but
that private helper was missing from the export list: in every inheriting
child shell the exported function existed, its dependency did not, so
resolution silently returned 1 ("[fh] warning: could not resolve version for
tilt"). kubernetes-client masked the defect in the SAME RUN only because its
installer sources the full helper library in its own shell.

Properties pinned here:

  1. behavioural (the exact defect): a parent shell that sources fh_helpers.sh
     (running its real `export -f` line) can resolve a pinned version from a
     CHILD `bash -c 'fh_resolve_version <tool>'` — this fails pre-fix;
  2. control: the same resolution works in the sourcing shell itself, proving
     the defect is export-inheritance, not parsing;
  3. structural: every fh_*/_fh_* function CALLED inside an exported
     function's body is itself on the `export -f` line — a recurrence guard;
  4. fail-closed: the checksum-pinned tools tilt/gh no longer chase upstream
     "latest" when resolution fails; they abort with FH_VERSION_UNRESOLVED.

Hermeticity: _fh_find_versions_json probes /tmp/versions.json,
/tmp/artefacts/versions.json and /opt/solen/artefacts/versions.json BEFORE any
FH_REPO_ROOT candidate; their absence is a hard precondition. The child runs
with cwd=tmp_path so the `./features/<tool>/check_version.py` hook fallback
cannot fire, and with FH_OFFLINE unset. No network is ever touched.
"""

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
FH_HELPERS = REPO / "features" / "_lib" / "fh_helpers.sh"

# Files _fh_find_versions_json probes BEFORE ${FH_REPO_ROOT}/artefacts/versions.json.
SHARED_VERSION_CANDIDATES = (
    "/tmp/versions.json",
    "/tmp/artefacts/versions.json",
    "/opt/solen/artefacts/versions.json",
)

# --- bash >= 4 resolution (macOS /bin/bash is 3.2); same approach as
# tests/test_download_direct_integrity_gate.py ---------------------------------
_BASH_CANDIDATES = [
    "/opt/homebrew/bin/bash",
    "/usr/local/bin/bash",
    "/bin/bash",
]


def _bash_major(path):
    try:
        out = subprocess.run(
            [path, "-c", 'echo "${BASH_VERSINFO[0]}"'],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
        return int(out.stdout.strip())
    except (ValueError, OSError):
        return 0


def _resolve_bash():
    found = shutil.which("bash")
    ordered = _BASH_CANDIDATES + ([found] if found and found not in _BASH_CANDIDATES else [])
    for cand in ordered:
        if Path(cand).is_file() and _bash_major(cand) >= 4:
            return cand
    return ""


BASH = _resolve_bash()

if not BASH:
    pytest.skip(
        "no bash >= 4 found; fh_helpers.sh requires bash 4+ (export -f)",
        allow_module_level=True,
    )


@pytest.fixture(autouse=True)
def _no_shared_version_state():
    for candidate in SHARED_VERSION_CANDIDATES:
        if Path(candidate).exists():
            pytest.fail(
                f"hermeticity precondition violated: {candidate} exists; "
                "_fh_find_versions_json probes it before FH_REPO_ROOT, so the "
                "staged versions.json would be ignored"
            )


def _stage_repo(tmp_path, tool, version):
    """A fake repo root exposing ${repo}/artefacts/versions.json like the image."""
    repo = tmp_path / "repo"
    artefacts = repo / "artefacts"
    artefacts.mkdir(parents=True)
    (artefacts / "versions.json").write_text(
        json.dumps({"meta": {"test-harness": True}, "tools": {tool: version}})
    )
    return repo


def _env_for(repo):
    env = os.environ.copy()
    env["FH_REPO_ROOT"] = str(repo)
    env["PATH"] = f"{os.path.dirname(sys.executable)}{os.pathsep}{env['PATH']}"
    env.pop("FH_OFFLINE", None)
    return env


class TestChildShellResolution:
    """The defect: child bash inherits fh_resolve_version but not its deps."""

    def test_child_bash_resolves_pinned_version_via_exported_function(self, tmp_path):
        tool, pinned = "tilt", "v9.9.9-pinned"
        repo = _stage_repo(tmp_path, tool, pinned)

        # Mirrors the generated Dockerfile: parent sources the helper library
        # (executing its real `export -f` line), then spawns a child bash that
        # calls the exported function — no re-sourcing in the child.
        driver = tmp_path / "parent.sh"
        driver.write_text(
            "#!/bin/bash\n"
            "set -uo pipefail\n"
            f"source '{FH_HELPERS}'\n"
            'bash -c \'fh_resolve_version "$1"\' _ "$1"\n'
            "exit $?\n"
        )

        proc = subprocess.run(
            [BASH, str(driver), tool],
            env=_env_for(repo),
            cwd=tmp_path,  # keeps ./features/<tool>/check_version.py out of reach
            capture_output=True,
            text=True,
            timeout=60,
            check=False,  # the rc of fh_resolve_version IS the assertion
        )
        assert proc.returncode == 0, (
            "child bash could not run the exported fh_resolve_version "
            f"(rc={proc.returncode}); pre-fix this fails with "
            "'_fh_find_versions_json: command not found' masked into an empty "
            f"vfile. stderr:\n{proc.stderr}"
        )
        assert proc.stdout == pinned, (
            f"expected the pinned version {pinned!r} on child stdout, "
            f"got {proc.stdout!r}"
        )

    def test_resolution_works_in_the_sourcing_shell_itself(self, tmp_path):
        """Control: parsing/staging are fine — only inheritance was broken."""
        tool, pinned = "tilt", "v9.9.9-pinned"
        repo = _stage_repo(tmp_path, tool, pinned)
        proc = subprocess.run(
            [BASH, "-c", f"source '{FH_HELPERS}' && fh_resolve_version '{tool}'"],
            env=_env_for(repo),
            cwd=tmp_path,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        assert proc.returncode == 0, proc.stderr
        assert proc.stdout == pinned


class TestExportListCoversCalledHelpers:
    """Recurrence guard: every helper called inside an exported function is exported."""

    _EXPORT_RE = re.compile(r"^export -f (.+)$", re.MULTILINE)
    _FUNC_DEF_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\)\s*\{", re.MULTILINE)
    # Call position: command substitution, or start of a command (line start,
    # after && / || / ; ), to a function-looking name in the fh namespace.
    _CALL_RE = re.compile(r"(?:\$\(|^|&&|\|\||;)\s*((?:_fh|fh)_[A-Za-z0-9_]+)[\s;)]", re.MULTILINE)

    def _exported_names(self, text):
        line = self._EXPORT_RE.search(text)
        assert line, "fh_helpers.sh must carry an `export -f` line"
        return set(line.group(1).split())

    def _function_bodies(self, text):
        """Map function name -> body, by brace matching from each definition."""
        bodies = {}
        for m in self._FUNC_DEF_RE.finditer(text):
            name = m.group(1)
            depth = 0
            i = m.end() - 1  # at the opening brace
            while i < len(text):
                if text[i] == "{":
                    depth += 1
                elif text[i] == "}":
                    depth -= 1
                    if depth == 0:
                        break
                i += 1
            bodies[name] = text[m.end() : i]
        return bodies

    def test_every_called_helper_within_exported_functions_is_exported(self):
        text = FH_HELPERS.read_text()
        exported = self._exported_names(text)
        bodies = self._function_bodies(text)
        defined = set(bodies)

        missing = set()
        for name in sorted(exported & defined):
            for ref in self._CALL_RE.findall(bodies[name]):
                if ref in defined and ref not in exported:
                    missing.add((name, ref))

        assert not missing, (
            "exported functions call non-exported helpers, which breaks every "
            "child shell that inherits them via export -f (the "
            "fh_resolve_version/_fh_find_versions_json defect): "
            + ", ".join(f"{outer} -> {inner}" for outer, inner in sorted(missing))
        )


class TestPinnedToolsFailClosed:
    """tilt/gh are checksum-pinned: an unresolvable version must abort, not chase upstream."""

    @pytest.mark.parametrize("feature", ["tilt", "gh"])
    def test_no_silent_latest_fallback(self, feature):
        text = (REPO / "features" / feature / "install.sh").read_text()
        assert "using latest" not in text, (
            f"{feature}: the 'using latest' fallback reintroduces drift between "
            "the mirror (pinned versions.json) and the GitHub-API rogue version"
        )
        assert "FH_VERSION_UNRESOLVED" in text, (
            f"{feature}: unresolvable version must abort with the named error"
        )
        assert re.search(r"FH_VERSION_UNRESOLVED[\s\S]{0,200}?\bexit 1\b", text), (
            f"{feature}: the named error must be followed by a non-zero exit"
        )

    def test_tilt_does_not_query_github_api_for_latest(self):
        text = (REPO / "features" / "tilt" / "install.sh").read_text()
        assert "api.github.com" not in text, (
            "tilt: resolving 'latest' via the GitHub API can only fail the "
            "fail-closed integrity gate (no checksums.json digest) or rely on "
            "digest coincidence; the designed latest mechanism is a "
            "per-feature check_version.py hook, which tilt does not ship"
        )
