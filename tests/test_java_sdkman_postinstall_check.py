"""Non-vacuity contract for the java-sdkman postInstallCheck.

The defect this pins down, measured -- ci-build run 38538835919, job
115768293009 (green leg, 2026-10-14, ``ghcr.io/ebpro/solen:quarto-full-develop``),
step "Run post-install contract checks" executing the OLD check::

    === RUN postInstallCheck: java-sdkman
    sdk not found
    OK postInstallCheck: java-sdkman

Two independent layers made that check incapable of ever failing::

    sh -c 'command -v sdk >/dev/null && sdk version || echo "sdk not found"'

1. ``sdk`` is an **unexported shell function** (upstream ``sdkman-main.sh``
   defines ``function sdk()``; ``~/.sdkman/bin`` ships ONLY ``sdkman-init.sh``
   -- no sdk executable, and zero ``export -f`` in the SDKMAN tree). The check
   wrapper ``/opt/solen/run-check-env.sh`` sources sdkman-init.sh into its own
   bash and then ``eval``s the command, but the ``sh -c`` fork started a CHILD
   shell that cannot inherit the function. The true branch never ran, on any
   image, ever.
2. ``|| echo "sdk not found"`` swallowed every exit status: the fallback echo
   exits 0, so healthy, corrupt and missing installs all produced rc 0. This
   is the root defect class: a trailing ``||`` inside a hard-gated check turns
   verification failure into verification success.

The replacement verifies exactly the two properties ``features/java-sdkman/
install.sh`` already hard-gates at build time (init artefact :55-68, and
``source sdkman-init.sh; command -v sdk`` as jovyan :101-112) in the same
shell the wrapper provides -- no ``||``, no child shell, no network, no
candidate paths (java-sdkman installs no candidate; lang-java-graal has no
java-jdk, so probing candidates would create a red leg, not a true check).

Hermeticity: the behavioural tests extract the REAL ``run-check-env.sh``
heredoc from ``solen-cli/solen/generators/dockerfile_template.j2`` -- never a
prose reimplementation -- and apply one mechanical, assert-guarded patch
(``user_home="/home/${user}"`` -> ``${TEST_USER_HOME:?}``) to sandbox it.
``TestWrapperContractPinned`` fails loudly if the template's wrapper shape
drifts, because the pass proof below is only as faithful as that extraction.
The shipped command is read from ``feature.json`` and its literal
``/home/jovyan`` root is path-redirected with an asserted replacement (repo
convention: ``test_graalvm_and_starship_fail_loud.py::_old_form``).

RED proof: the old command is fetched from the pinned pre-fix SHA
``3189c75`` (never HEAD, so this can never self-reference the current form)
and shown to exit 0 in ALL states -- healthy, corrupt, missing -- while the
new command exits 0 only when healthy.
"""

import json
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
TEMPLATE = REPO / "solen-cli" / "solen" / "generators" / "dockerfile_template.j2"
FEATURE_JSON = REPO / "features" / "java-sdkman" / "feature.json"

#: Commit whose shipped java-sdkman check produced the "sdk not found / OK"
#: production log quoted above. Pinned, never HEAD: the RED proof must not be
#: able to degrade into comparing the current form against itself.
VACUOUS_BASELINE_SHA = "3189c75"

CHECK = json.loads(FEATURE_JSON.read_text(encoding="utf-8"))["postInstallCheck"]
COMMAND = CHECK["command"]

_HEREDOC_START = "RUN cat > /opt/solen/run-check-env.sh <<'SCRIPT'\n"
_HEREDOC_END = "\nSCRIPT\n"


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


def _extract_wrapper() -> str:
    """Bytes of the real run-check-env.sh heredoc, read from the template."""
    text = TEMPLATE.read_text(encoding="utf-8")
    start = text.find(_HEREDOC_START)
    assert start != -1, (
        "run-check-env.sh heredoc marker vanished from dockerfile_template.j2 "
        "-- the java-sdkman check tests extract it to stay faithful; re-pin _HEREDOC_START"
    )
    body = text[start + len(_HEREDOC_START):]
    end = body.find(_HEREDOC_END)
    assert end != -1, "run-check-env.sh heredoc is unterminated in the template"
    return body[:end]


class TestWrapperContractPinned:
    """The replacement's pass proof rests on the wrapper's exact shape.

    The new command resolves ``sdk`` only because run-check-env.sh sources
    sdkman-init.sh into the SAME shell that evals the check. If that block is
    ever removed or altered, the check would false-FAIL on healthy installs --
    surface the coupling here instead of in a red publish gate.
    """

    def test_wrapper_sources_sdkman_init_into_the_eval_shell(self):
        wrapper = _extract_wrapper()
        assert 'if [ -f "${user_home}/.sdkman/bin/sdkman-init.sh" ]; then' in wrapper
        assert '. "${user_home}/.sdkman/bin/sdkman-init.sh" >/dev/null 2>&1 || true' in wrapper
        assert 'eval "${check_cmd}"' in wrapper

    def test_wrapper_user_home_line_is_the_patched_form(self):
        # _WrapperSandbox replaces this exact line; fail loudly on drift.
        assert 'user_home="/home/${user}"' in _extract_wrapper()


def _vacuous_baseline_command() -> str:
    proc = subprocess.run(
        ["git", "-C", str(REPO), "show", f"{VACUOUS_BASELINE_SHA}:features/java-sdkman/feature.json"],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        pytest.skip(f"baseline {VACUOUS_BASELINE_SHA} not reachable in this clone (shallow?)")
    old = json.loads(proc.stdout)["postInstallCheck"]["command"]
    assert "|| echo" in old, (
        f"baseline {VACUOUS_BASELINE_SHA} no longer holds the vacuous form -- re-pin VACUOUS_BASELINE_SHA"
    )
    assert old != COMMAND, "RED proof would be self-referential (old == current command)"
    return old


class _WrapperSandbox:
    """Faithful, hermetic runner for the REAL extracted wrapper.

    One mechanical patch (asserted): ``user_home`` comes from TEST_USER_HOME
    instead of ``/home/${user}``. The check command's literal ``/home/jovyan``
    root is redirected into the sandbox the same asserted way, so the check
    and the wrapper's source guard look at the same sandboxed tree.
    """

    def __init__(self, tmp_path: Path, tag: str):
        self.root = tmp_path / tag
        self.home = self.root / "home"
        self.sdkman = self.home / ".sdkman"
        self.init = self.sdkman / "bin" / "sdkman-init.sh"
        self.home.mkdir(parents=True)

        wrapper = _extract_wrapper()
        needle = 'user_home="/home/${user}"'
        assert needle in wrapper, "wrapper user_home line drifted; patch would be a silent no-op"
        patched = wrapper.replace(needle, 'user_home="${TEST_USER_HOME:?}"')
        assert patched != wrapper
        self.wrapper = self.root / "run-check-env.sh"
        self.wrapper.write_text(patched, encoding="utf-8")

    def make_init(self, mode: str) -> None:
        if mode == "missing":
            return
        self.init.parent.mkdir(parents=True, exist_ok=True)
        if mode == "function":
            # Faithful to upstream: `sdk` is a plain shell function, NOT an
            # executable and NOT export -f'd.
            self.init.write_text('sdk() {\n  echo "SDKMAN: fake 5.18.2"\n}\n', encoding="utf-8")
        elif mode == "corrupt":
            self.init.write_text("# truncated sdkman install: defines nothing\n", encoding="utf-8")
        else:  # pragma: no cover - guard against harness typos
            raise ValueError(mode)

    def redirect(self, command: str) -> str:
        if "/home/jovyan" in command:
            redirected = command.replace("/home/jovyan", str(self.home))
            assert redirected != command
            return redirected
        return command

    def run(self, command: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [BASH, str(self.wrapper), "jovyan", self.redirect(command)],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
            env={
                "TEST_USER_HOME": str(self.home),
                "PATH": "/usr/bin:/bin",
                "HOME": str(self.home),
                "NB_USER": "jovyan",
            },
        )


@pytest.mark.skipif(not BASH, reason="no bash >= 4 found")
class TestCommandShape:
    """Static guards on the shipped bytes. The two clauses each encode one
    layer of the vacuity defect, so they generalise beyond this command."""

    def test_no_exit_status_swallowing(self):
        assert "||" not in COMMAND, (
            "a trailing || in a hard-gated check converts verification failure "
            "into verification success (root defect of the pre-fix form)"
        )

    def test_no_child_shell_wrapper(self):
        for forbidden in ("sh -c", "bash -c", "bash -lc", "zsh -c"):
            assert forbidden not in COMMAND, (
                f"{forbidden!r} forks a child shell that cannot see sdk: it is an "
                "unexported function sourced only into run-check-env.sh's own bash"
            )

    def test_anchors_on_installer_verified_artefacts(self):
        assert "test -s /home/jovyan/.sdkman/bin/sdkman-init.sh" in COMMAND
        assert "command -v sdk" in COMMAND

    def test_success_marker_present(self):
        assert 'echo "java-sdkman: check OK' in COMMAND

    def test_description_is_specific(self):
        assert CHECK["description"].strip()
        assert "sdkman-init.sh" in CHECK["description"]


@pytest.mark.skipif(not BASH, reason="no bash >= 4 found")
class TestNonVacuousBehaviour:
    """Behaviour through the real extracted wrapper, all three states."""

    def test_healthy_install_passes(self, tmp_path):
        sbx = _WrapperSandbox(tmp_path, "healthy")
        sbx.make_init(mode="function")
        result = sbx.run(COMMAND)
        assert result.returncode == 0, result
        assert "java-sdkman: check OK" in result.stdout

    def test_missing_artefact_fails(self, tmp_path):
        sbx = _WrapperSandbox(tmp_path, "missing")
        sbx.make_init(mode="missing")
        result = sbx.run(COMMAND)
        assert result.returncode != 0, "check must go red when the installer artefact is absent"
        assert "check OK" not in result.stdout

    def test_artefact_without_function_fails(self, tmp_path):
        # The discriminating case: artefact present but transport dead.
        sbx = _WrapperSandbox(tmp_path, "corrupt")
        sbx.make_init(mode="corrupt")
        result = sbx.run(COMMAND)
        assert result.returncode != 0, "check must go red when sourcing yields no resolvable sdk"

    def test_generator_embeds_the_shipped_command(self, tmp_path):
        from solen.core.feature import collect_post_install_checks

        checks = collect_post_install_checks(REPO / "features", ["java-sdkman"])
        assert checks and checks[0]["id"] == "java-sdkman"
        assert checks[0]["command"] == COMMAND


@pytest.mark.skipif(not BASH, reason="no bash >= 4 found")
class TestChildShellInvisibility:
    """Encodes the vacuity mechanism itself: a sourced, non-exported function
    does not cross into ``sh -c`` children. On the real image /bin/sh is dash
    -- even further from sdkman-init's bash-only syntax -- so any check that
    resolves sdk inside a child shell can only ever take its false branch."""

    def test_parent_resolves_but_child_does_not(self, tmp_path):
        sbx = _WrapperSandbox(tmp_path, "child")
        sbx.make_init(mode="function")
        source = f'. "{sbx.init}" >/dev/null 2>&1'

        parent = subprocess.run(
            [BASH, "-c", f"set +u; {source}; set -u; command -v sdk >/dev/null"],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        assert parent.returncode == 0, "harness broken: parent shell must resolve the function"

        child = subprocess.run(
            [BASH, "-c", f"set +u; {source}; set -u; sh -c 'command -v sdk >/dev/null'"],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        assert child.returncode != 0, (
            "child shell resolved sdk -- the old form's false branch premise broke; "
            "re-examine before trusting this file's RED proof"
        )


@pytest.mark.skipif(not BASH, reason="no bash >= 4 found")
class TestRedProofVacuousBaseline:
    """The pinned pre-fix command exits 0 in EVERY state, including a healthy
    install -- where it printed the exact production-log line ``sdk not
    found`` while the gate reported OK. The new command discriminates."""

    @pytest.mark.parametrize("mode", ["function", "corrupt", "missing"])
    def test_old_form_survives_every_state(self, tmp_path, mode):
        old = _vacuous_baseline_command()
        sbx = _WrapperSandbox(tmp_path, f"old-{mode}")
        sbx.make_init(mode=mode)
        result = sbx.run(old)
        assert result.returncode == 0, f"baseline unexpectedly failed in {mode} state: {result}"

    def test_old_form_reports_failure_on_a_healthy_install(self, tmp_path):
        old = _vacuous_baseline_command()
        sbx = _WrapperSandbox(tmp_path, "old-healthy-signature")
        sbx.make_init(mode="function")
        result = sbx.run(old)
        assert "sdk not found" in result.stdout, (
            "the healthy image hit the FALSE branch of the old check, exactly as in "
            "the production log, yet the gate still exited 0 -- that is the vacuity"
        )
        assert result.returncode == 0

    @pytest.mark.parametrize(
        ("mode", "expect_pass"),
        [("function", True), ("corrupt", False), ("missing", False)],
    )
    def test_new_form_discriminates_where_old_could_not(self, tmp_path, mode, expect_pass):
        sbx = _WrapperSandbox(tmp_path, f"new-{mode}")
        sbx.make_init(mode=mode)
        result = sbx.run(COMMAND)
        assert (result.returncode == 0) is expect_pass
