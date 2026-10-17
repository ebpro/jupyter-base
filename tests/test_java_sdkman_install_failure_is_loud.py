"""Regression tests for the java-sdkman / java-jdk / java-maven / java-gradle
fail-loud contract (CI run 39053927880, the 7-minute misattribution chain).

`features/java-sdkman/install.sh` used to end its installer pipeline in
`|| true`, and its only post-install probe printed a warning and exited 0:

    curl: (35) Recv failure: Connection reset by peer
    'curl --fail --location ... sdkman/install/...': command failed with exit code 35.
    java-sdk: SDKMAN installation completed but 'sdk' not exposed in PATH for jovyan
    java-sdk: SDKMAN installation complete                      <-- exit 0

The failing download is INSIDE the upstream get.sdkman.io script, so the
status was only observable through the pipeline (hence the subshell `pipefail`
in the fix). Six to eight minutes later the *consumer* aborted, in the wrong
file:

    java-maven: ERROR - SDKMAN not available. Please include java-sdkman feature first.

The same masking existed on every consumer install (`sdk install java|maven|
gradle ... || true`) and on every consumer verify (WARNING + `done`). That is
not hypothetical: build-arm64 SUCCEEDED on a leg whose log contains
"Download has failed, aborting!" / "Can not install java 25.0.4.1+1-tem at
this time..." / "java-jdk: WARNING - java command not available after
installation" — a green leg publishing an image with no Java in it.

These tests run the REAL shipped installers in a bash subprocess with `su`,
`curl` and `sdk` stubbed, and pin:

  1. java-sdkman: a failed fetch aborts at the producer (rc 1,
     FH_SDKMAN_INSTALL_FAILED, naming the consumers that would have taken the
     blame) and installs nothing;
  2. java-sdkman: an installer that exits 0 having written no
     ~/.sdkman/bin/sdkman-init.sh aborts on the artefact post-condition;
  3. java-sdkman: with a tree already present, the abort comes from the
     PIPELINE status alone — the artefact gate would have passed — which is
     precisely what `pipefail` buys (without it, `bash` exits 0 and the fetch
     failure is invisible again);
  4. java-sdkman: `sdk` unresolvable for the target user after sourcing the
     init script is fatal instead of a warning;
  5. java-sdkman: the happy path exits 0 with stdout byte-identical to the
     pre-fix installer (behaviour unchanged when the install works);
  6. java-jdk / java-maven / java-gradle: a failing `sdk install <candidate>`
     and a successful install that materialises no binary are both fatal and
     both name java-sdkman as the producer; their `SDKMAN not available`
     early abort is preserved;
  7. RED proof: the pre-fix installer (git show bd1d66d) exits 0 on the exact
     inputs above, so these assertions genuinely discriminate the fix.

Hermeticity: PATH is the stub directory ALONE — system directories are never
appended, or a host-wide java/mvn/sdk would satisfy the installers'
"already installed" branches and the failure paths would test nothing (see the
lesson recorded in tests/test_kotlin_install_failure_is_loud.py). Only the
plumbing binaries the scripts genuinely need are symlinked in, explicitly. No
network is touched: `curl` is a stub in every mode, including the one that
"installs" SDKMAN, which emits a bootstrap script that writes a fake
sdkman-init.sh pointing at a stub `sdk`. No container, no root, no shared /tmp
residue: everything lives under pytest's tmp_path.
"""

import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
SDKMAN_SH = REPO / "features" / "java-sdkman" / "install.sh"

# Last revision whose java installers still masked the failures with `|| true`
# (the tree was clean at this SHA when the fix was written). Pinned to a SHA,
# not HEAD, so the RED proofs keep working after the fix is committed — same
# convention as tests/test_kotlin_install_failure_is_loud.py.
OLD_FORM_REF = "bd1d66d"

# The named-error tokens the fix emits (convention: FH_<NAME>, cf.
# FH_VERSION_UNRESOLVED in features/gh/install.sh and features/tilt/install.sh).
SDKMAN_TOKEN = "FH_SDKMAN_INSTALL_FAILED"

# --- bash >= 4 resolution (macOS /bin/bash is 3.2); same approach as
# tests/test_download_direct_integrity_gate.py ---------------------------------
_CANDIDATES = [
    "/opt/homebrew/bin/bash",
    "/usr/local/bin/bash",
    "/bin/bash",
]


def _bash_major(path: str) -> int:
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


def _resolve_bash() -> str:
    found = shutil.which("bash")
    ordered = _CANDIDATES + ([found] if found and found not in _CANDIDATES else [])
    for cand in ordered:
        if Path(cand).is_file() and _bash_major(cand) >= 4:
            return cand
    return ""


BASH = _resolve_bash()

if not BASH:
    pytest.skip(
        "no bash >= 4 found; the java feature installers require bash 4+",
        allow_module_level=True,
    )

# External commands the four installers (and their stubbed `su` children)
# actually invoke. Everything else they use is a bash builtin. Staged by
# absolute path so the scrubbed PATH stays a closed set.
_PLUMBING = (
    "awk",
    "cat",
    "chmod",
    "chown",
    "cp",
    "cut",
    "grep",
    "head",
    "id",
    "mkdir",
    "mktemp",
    "rm",
    "sed",
    "stat",
    "tr",
)

# Content of a candidate binary the stub `sdk` "installs". `java -version`
# writes to stderr upstream, so the stub does too (nothing here asserts on it).
_STAGED_BINS = {
    "java": "#!/bin/bash\necho 'openjdk version \"25.0.4\" 2025-07-15' >&2\nexit 0\n",
    "mvn": "#!/bin/bash\necho 'Apache Maven 3.9.11'\nexit 0\n",
    "gradle": "#!/bin/bash\necho 'Gradle 8.14'\nexit 0\n",
}


def _write_exec(path: Path, body: str) -> None:
    # Absolute interpreter, never `#!/usr/bin/env bash`: the sandbox PATH is
    # scrubbed, so an env-shebang stub could not find bash.
    path.write_text("#!" + BASH + "\n" + body, encoding="utf-8")
    path.chmod(0o755)


class _Sandbox:
    """Fake host for one installer run.

    * ``bin``      — the ONLY PATH entry of the installer process;
    * ``userbin``  — reachable only through the fake ``sdkman-init.sh``, i.e.
                     exactly where a real SDKMAN puts its shims;
    * ``home``     — fake ``$HOME`` for both the installer and the ``su``'d
                     target user, so ``$SDKMAN_DIR`` (default
                     ``$HOME/.sdkman``) has one unambiguous value.
    """

    def __init__(self, tmp_path: Path, tag: str) -> None:
        self.root = tmp_path / tag
        self.bin = self.root / "bin"
        self.userbin = self.root / "userbin"
        self.home = self.root / "home"
        self.staging = self.root / "staging"
        self.sdkman = self.home / ".sdkman"
        for d in (self.bin, self.userbin, self.home, self.staging):
            d.mkdir(parents=True)

        (self.bin / "bash").symlink_to(BASH)
        for name in _PLUMBING:
            src = shutil.which(name)
            if src is not None:
                (self.bin / name).symlink_to(src)

        for name, body in _STAGED_BINS.items():
            staged = self.staging / name
            staged.write_text(body, encoding="utf-8")
            staged.chmod(0o755)

        self.bootstrap = self.root / "get-sdkman.sh"
        self.bootstrap.write_text(
            "#!/bin/bash\n"
            'SDKMAN_DIR="${SDKMAN_DIR:-$HOME/.sdkman}"\n'
            'mkdir -p "$SDKMAN_DIR/bin"\n'
            "printf '%s\\n' 'export PATH=\"" + str(self.userbin) + ':$PATH"\' '
            '> "$SDKMAN_DIR/bin/sdkman-init.sh"\n'
            "exit 0\n",
            encoding="utf-8",
        )

        self._write_su_stub()
        self.set_curl("empty")
        self.set_sdk({})

    # -- stubs ---------------------------------------------------------------
    def _write_su_stub(self) -> None:
        """`su - <user> -s /bin/bash (-c|-lc) <cmd>` stub.

        Reproduces the three observable properties of util-linux `su` these
        installers rely on: (1) the command runs with the TARGET USER's HOME,
        (2) a login shell has SDKMAN on PATH because the user's profile chain
        sources ~/.sdkman/bin/sdkman-init.sh, (3) su's exit status is the
        command's exit status. PATH is rebuilt from scratch (never inherited)
        so nothing from the host can leak in.
        """
        body = (
            "# Stub su.\n"
            'cmd="${@: -1}"\n'
            "login=0\n"
            "case \" $* \" in\n"
            '  *" -l "*|*" -lc "*|*" -cl "*) login=1 ;;\n'
            "esac\n"
            "export HOME='" + str(self.home) + "'\n"
            "export PATH='" + str(self.bin) + "'\n"
            "unset SDKMAN_DIR\n"
            "init='" + str(self.home) + "/.sdkman/bin/sdkman-init.sh'\n"
            'if [ "$login" = 1 ] && [ -s "$init" ]; then\n'
            "  source \"$init\" || true\n"
            "fi\n"
            "exec '" + BASH + "' -c \"$cmd\"\n"
        )
        _write_exec(self.bin / "su", body)

    def set_curl(self, mode: str) -> None:
        """`fail35` the observed transient egress error; `empty` the upstream
        installer exiting 0 having installed nothing; `install` a working
        install (emits the bootstrap script the installer pipes into bash)."""
        if mode == "fail35":
            body = (
                "# Stub curl: the CI 39053927880 failure, verbatim.\n"
                "echo 'curl: (35) Recv failure: Connection reset by peer' >&2\n"
                "exit 35\n"
            )
        elif mode == "empty":
            body = "# Stub curl: succeeds, serves nothing.\nexit 0\n"
        elif mode == "install":
            body = (
                "# Stub curl: serves the (fake) upstream installer script on stdout.\n"
                "cat '" + str(self.bootstrap) + "'\n"
                "exit 0\n"
            )
        else:  # pragma: no cover - harness misuse
            raise ValueError(f"unknown curl mode {mode!r}")
        _write_exec(self.bin / "curl", body)

    def set_sdk(self, installs: dict) -> None:
        """installs: candidate -> (exit status, binary to materialise or None).

        `install` is the build-time network fetch stage under test; every other
        subcommand (`list`, `version`) succeeds and prints nothing, so
        candidate DISCOVERY resolves to "no candidate" and the installers take
        their documented fallback branch.
        """
        lines = [
            "# Stub sdk. Never touches the network.",
            'echo "sdk-stub: $*" >&2',
            'if [ "${1:-}" = "install" ]; then',
            '  case "${2:-}" in',
        ]
        for candidate, (rc, produce) in installs.items():
            lines.append("    " + candidate + ")")
            if produce is not None:
                target = str(self.userbin / produce)
                lines.append('      cp "' + str(self.staging / produce) + '" "' + target + '"')
                lines.append('      chmod 755 "' + target + '"')
            lines.append("      exit " + str(rc))
            lines.append("      ;;")
        lines += ["    *) exit 0 ;;", "    esac", "  fi", "exit 0", ""]
        _write_exec(self.userbin / "sdk", "\n".join(lines))

    def preinstall_sdkman(self, *, exposes_sdk: bool = True) -> Path:
        """Write the init artefact by hand (partial/complete install states)."""
        init = self.sdkman / "bin" / "sdkman-init.sh"
        init.parent.mkdir(parents=True, exist_ok=True)
        if exposes_sdk:
            init.write_text('export PATH="' + str(self.userbin) + ':$PATH"\n', encoding="utf-8")
        else:
            init.write_text("# partial install: exposes nothing\n", encoding="utf-8")
        return init

    # -- execution -----------------------------------------------------------
    def run(self, installer: Path, env_extra: dict | None = None):
        env = {"PATH": str(self.bin), "HOME": str(self.home), "TMPDIR": str(self.root)}
        env.update(env_extra or {})
        return subprocess.run(
            [BASH, str(installer)],
            capture_output=True,
            text=True,
            env=env,
            timeout=60,
            cwd=str(self.root),
            check=False,  # the installer's rc IS the assertion
        )


def _old_form(feature: str, dest_dir: Path) -> Path:
    proc = subprocess.run(
        ["git", "-C", str(REPO), "show", f"{OLD_FORM_REF}:features/{feature}/install.sh"],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0 or "|| true" not in proc.stdout:
        pytest.skip(f"pre-fix installer not retrievable at {OLD_FORM_REF} (shallow clone?)")
    path = dest_dir / f"install_old_{feature}.sh"
    path.write_text(proc.stdout, encoding="utf-8")
    path.chmod(0o755)
    return path


class TestSdkmanFailsLoud:
    """Change 1: java-sdkman must not exit 0 having installed nothing."""

    def test_egress_failure_aborts_at_the_producer(self, tmp_path):
        sb = _Sandbox(tmp_path, "egress")
        sb.set_curl("fail35")

        proc = sb.run(SDKMAN_SH)

        assert proc.returncode == 1, (
            f"installer masked a failing SDKMAN fetch: rc={proc.returncode} "
            f"stderr={proc.stderr!r}"
        )
        assert SDKMAN_TOKEN in proc.stderr
        assert "exited 35" in proc.stderr  # the pipeline status survived
        # Attribution: the failure names the consumers that used to absorb it.
        assert "java-jdk" in proc.stderr and "java-maven" in proc.stderr
        # The green-with-nothing banner must be gone.
        assert "java-sdk: SDKMAN installation complete" not in proc.stdout
        assert "java-sdk: SDKMAN installed for" not in proc.stdout
        assert not (sb.sdkman / "bin" / "sdkman-init.sh").exists()

    def test_installer_exiting_zero_without_artefact_aborts(self, tmp_path):
        sb = _Sandbox(tmp_path, "no-artefact")
        sb.set_curl("empty")  # upstream exits 0 and installs nothing

        proc = sb.run(SDKMAN_SH)

        assert proc.returncode == 1, proc.stdout
        assert SDKMAN_TOKEN in proc.stderr
        assert "no init artefact" in proc.stderr  # the post-condition, not the rc
        assert "java-sdk: SDKMAN installation complete" not in proc.stdout

    def test_pipefail_gate_aborts_even_with_a_tree_present(self, tmp_path):
        """The artefact gate would PASS here; only `pipefail` aborts the run.

        Without pipefail the pipeline's status is `bash`'s (0: it happily ran
        the truncated/empty script), so a failed fetch with a tree already in
        place would still exit 0 — the half of the fix the artefact check
        alone cannot provide.
        """
        sb = _Sandbox(tmp_path, "pipefail")
        sb.preinstall_sdkman()
        sb.set_curl("fail35")

        proc = sb.run(SDKMAN_SH)

        assert proc.returncode == 1, proc.stdout
        assert SDKMAN_TOKEN in proc.stderr
        assert "exited 35" in proc.stderr
        assert "no init artefact" not in proc.stderr  # a different gate fired

    def test_sdk_unresolvable_after_init_is_fatal(self, tmp_path):
        """The old 'sdk not exposed in PATH' warning + exit 0 is now fatal."""
        sb = _Sandbox(tmp_path, "not-exposed")
        sb.preinstall_sdkman(exposes_sdk=False)
        sb.set_curl("empty")

        proc = sb.run(SDKMAN_SH)

        assert proc.returncode == 1, proc.stdout
        assert SDKMAN_TOKEN in proc.stderr
        assert "not resolvable" in proc.stderr
        assert "java-sdk: SDKMAN installed for" not in proc.stdout
        assert "java-sdk: SDKMAN installation complete" not in proc.stdout

    def test_happy_path_exits_zero_and_stdout_is_unchanged(self, tmp_path):
        sb = _Sandbox(tmp_path, "happy")
        sb.set_curl("install")

        new = sb.run(SDKMAN_SH)
        assert new.returncode == 0, new.stderr
        assert SDKMAN_TOKEN not in new.stderr
        assert (sb.sdkman / "bin" / "sdkman-init.sh").is_file()
        assert "java-sdk: SDKMAN installed for jovyan" in new.stdout
        assert "java-sdk: SDKMAN installation complete" in new.stdout

        # Same sandbox, so paths in the banner are comparable: the fix must not
        # change a successful install's observable output.
        old = sb.run(_old_form("java-sdkman", sb.root))
        assert old.returncode == 0, old.stderr
        assert new.stdout == old.stdout

    @pytest.mark.parametrize(
        ("mode", "preinstall"),
        [("fail35", False), ("empty", False), ("fail35", True)],
        ids=["egress", "installed-nothing", "egress-with-partial-tree"],
    )
    def test_red_proof_old_form_stayed_green(self, tmp_path, mode, preinstall):
        """bd1d66d exits 0 on the very inputs that now abort."""
        sb = _Sandbox(tmp_path, f"red-{mode}-{preinstall}")
        if preinstall:
            sb.preinstall_sdkman()
        sb.set_curl(mode)

        old = sb.run(_old_form("java-sdkman", sb.root))
        assert old.returncode == 0, (
            f"old form unexpectedly failed (rc={old.returncode}); the input no "
            "longer discriminates and the new-form tests may be vacuous"
        )
        assert "java-sdk: SDKMAN installation complete" in old.stdout
        if not preinstall:
            # The exact misattribution line from the CI log.
            assert "SDKMAN installation completed but 'sdk' not exposed in PATH" in old.stderr

        new = sb.run(SDKMAN_SH)
        assert new.returncode == 1
        assert SDKMAN_TOKEN in new.stderr


_CONSUMERS = {
    "java-maven": {
        "candidate": "maven",
        "binary": "mvn",
        "install_token": "FH_JAVA_MAVEN_INSTALL_FAILED",
        "verify_token": "FH_JAVA_MAVEN_NOT_AVAILABLE",
        "warning": "WARNING - mvn command not available after installation",
        "env": {},
    },
    "java-gradle": {
        "candidate": "gradle",
        "binary": "gradle",
        "install_token": "FH_JAVA_GRADLE_INSTALL_FAILED",
        "verify_token": "FH_JAVA_GRADLE_NOT_AVAILABLE",
        "warning": "WARNING - gradle command not available after installation",
        "env": {},
    },
    "java-jdk": {
        "candidate": "java",
        "binary": "java",
        "install_token": "FH_JAVA_JDK_INSTALL_FAILED",
        "verify_token": "FH_JAVA_JDK_NOT_AVAILABLE",
        "warning": "WARNING - java command not available after installation",
        # Case 5 (specific identifier). The production default (numeric) is
        # covered separately, because `sdk list java` output is upstream-owned
        # and deliberately not pinned by these stubs.
        "env": {"JDK_VERSION": "25.0.4.1+1-tem"},
    },
}


class TestConsumersFailLoud:
    """Changes 2 and 3: candidate installs and their post-conditions."""

    @pytest.mark.parametrize("feature", sorted(_CONSUMERS))
    def test_candidate_install_failure_is_fatal_and_names_the_producer(
        self, tmp_path, feature
    ):
        spec = _CONSUMERS[feature]
        sb = _Sandbox(tmp_path, f"{feature}-install")
        sb.preinstall_sdkman()
        sb.set_sdk({spec["candidate"]: (1, None)})

        proc = sb.run(REPO / "features" / feature / "install.sh", spec["env"])

        assert proc.returncode == 1, (
            f"{feature} masked a failing sdk install: rc={proc.returncode} "
            f"stderr={proc.stderr!r}"
        )
        assert spec["install_token"] in proc.stderr
        assert "java-sdkman" in proc.stderr  # the producer, not just the consumer
        assert "sdk install " + spec["candidate"] in proc.stderr  # the attempted cmd
        assert f"{feature}: done" not in proc.stdout

    @pytest.mark.parametrize("feature", sorted(_CONSUMERS))
    def test_install_claiming_success_without_the_binary_is_fatal(self, tmp_path, feature):
        spec = _CONSUMERS[feature]
        sb = _Sandbox(tmp_path, f"{feature}-no-bin")
        sb.preinstall_sdkman()
        sb.set_sdk({spec["candidate"]: (0, None)})  # exit 0, materialises nothing

        proc = sb.run(REPO / "features" / feature / "install.sh", spec["env"])

        assert proc.returncode == 1, proc.stdout
        assert spec["verify_token"] in proc.stderr
        assert "java-sdkman" in proc.stderr
        assert f"{feature}: installation successful" not in proc.stdout
        assert f"{feature}: done" not in proc.stdout

    @pytest.mark.parametrize("feature", sorted(_CONSUMERS))
    def test_happy_path_installs_and_reports_success(self, tmp_path, feature):
        spec = _CONSUMERS[feature]
        sb = _Sandbox(tmp_path, f"{feature}-ok")
        sb.preinstall_sdkman()
        sb.set_sdk({spec["candidate"]: (0, spec["binary"])})

        proc = sb.run(REPO / "features" / feature / "install.sh", spec["env"])

        assert proc.returncode == 0, proc.stderr
        assert f"{feature}: installation successful" in proc.stdout
        assert f"{feature}: done" in proc.stdout
        assert "FAILED" not in proc.stderr

    @pytest.mark.parametrize("feature", sorted(_CONSUMERS))
    @pytest.mark.parametrize("rc", [1, 0], ids=["install-failed", "binary-missing"])
    def test_red_proof_old_form_shipped_green_without_the_tool(self, tmp_path, feature, rc):
        """The arm64 signature: rc 0, a WARNING, and no binary in the image."""
        spec = _CONSUMERS[feature]
        sb = _Sandbox(tmp_path, f"{feature}-red-{rc}")
        sb.preinstall_sdkman()
        sb.set_sdk({spec["candidate"]: (rc, None)})

        old = sb.run(_old_form(feature, sb.root), spec["env"])
        assert old.returncode == 0, (
            f"old {feature} unexpectedly failed (rc={old.returncode}); the input "
            "no longer discriminates"
        )
        assert spec["warning"] in old.stderr
        assert f"{feature}: done" in old.stdout

        new = sb.run(REPO / "features" / feature / "install.sh", spec["env"])
        assert new.returncode == 1
        assert spec["install_token" if rc else "verify_token"] in new.stderr


class TestConsumerContractPreserved:
    """Change 3/4: nothing that used to be a correct early abort got softer,
    and no supported configuration became a hard failure."""

    @pytest.mark.parametrize("feature", ["java-jdk", "java-maven", "java-gradle"])
    def test_sdkman_absent_still_aborts_naming_the_producer(self, tmp_path, feature):
        sb = _Sandbox(tmp_path, f"{feature}-no-sdkman")
        # No artefact, no sdk anywhere: the accurate early signal.
        proc = sb.run(REPO / "features" / feature / "install.sh")
        assert proc.returncode == 1
        assert "ERROR - SDKMAN not available" in proc.stderr
        assert "Please include java-sdkman feature first" in proc.stderr

    def test_java_jdk_default_numeric_pin_fails_loud(self, tmp_path):
        """Production's real shape: JDK_VERSION=25, no candidate resolves from
        `sdk list java`, the documented fallback install fails -> abort."""
        sb = _Sandbox(tmp_path, "jdk-numeric")
        sb.preinstall_sdkman()
        sb.set_sdk({"java": (1, None)})

        proc = sb.run(REPO / "features" / "java-jdk" / "install.sh")

        assert proc.returncode == 1, proc.stdout
        assert "FH_JAVA_JDK_INSTALL_FAILED" in proc.stderr
        assert "java-jdk: no matching temurin candidate for version 25" in proc.stdout
        assert "java-jdk: done" not in proc.stdout

        old = sb.run(_old_form("java-jdk", sb.root))
        assert old.returncode == 0
        assert "WARNING - java command not available after installation" in old.stderr
