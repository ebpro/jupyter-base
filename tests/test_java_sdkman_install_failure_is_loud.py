"""Regression tests for the java-sdkman / java-jdk / java-maven fail-loud
contract (CI run 39053927880, the 7-minute misattribution chain).
java-gradle is no longer a consumer of the SDKMAN transport; its mirrored
install is guarded by tests/test_java_gradle_is_mirrored.py.

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
  6. java-jdk / java-maven: a failing `sdk install <candidate>`
     and a successful install that materialises no binary are both fatal; the
     install-failure paths name java-sdkman as the producer, the verify paths
     name the exact artefact the probe checked for and did not find; their
     `SDKMAN not available` early abort is preserved;
  7. RED proof: the pre-fix installer (git show bd1d66d) exits 0 on the exact
     inputs above, so these assertions genuinely discriminate the fix;
  8. faithful environment (the 8da2bd8 false-positive guard): the `su` stub
     gains a mode whose login shell does NOT source sdkman-init.sh — the real
     state during the feature loop, because /etc/profile.d/solen.sh is
     written only by the RUN that follows it
     (solen-cli/solen/generators/dockerfile_template.j2:240-243). In that
     environment the 8da2bd8 bare-`command -v` probes FAIL on a healthy
     install (rc 1, FH_*_NOT_AVAILABLE — the abort that blocked trunk 3/3)
     while the init-sourcing probes PASS; in the legacy synthetic-sourcing
     mode the defective probes pass, which is exactly the harness flaw that
     hid the false positive. Both directions are pinned.

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

# The revision whose consumer verify probes WERE the false positive: a bare
# `command -v` in a login shell, un-satisfiable before the profile hook
# exists. Pinned to a SHA, like OLD_FORM_REF, so the faithful-environment
# discrimination keeps working after the fix is committed.
FALSE_POSITIVE_REF = "8da2bd8"

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
    * ``userbin``  — the shim dir the fake ``sdkman-init.sh`` exports (where
                     the stub ``sdk`` lives);
    * ``home/.sdkman/candidates/<tool>/current/bin`` — where candidate
                     binaries are materialised, exactly like the real SDKMAN,
                     and what the fake init exports by iterating the
                     candidate dirs at source time;
    * ``home``     — fake ``$HOME`` for both the installer and the ``su``'d
                     target user, so ``$SDKMAN_DIR`` (default
                     ``$HOME/.sdkman``) has one unambiguous value.

    ``faithful=True`` switches the ``su`` stub to the real pre-:243 state:
    the login shell sources NOTHING, so SDKMAN tools are reachable only to a
    command that sources ``sdkman-init.sh`` itself. The default keeps the
    legacy synthetic-sourcing login branch, which the java-sdkman
    happy-path stdout-parity proofs of the pre-fix installer still rely on.
    """

    # The candidate export the real sdkman-init.sh performs: every installed
    # candidate contributes current/bin to PATH, at source time only. Ends in
    # a statement that cannot leave a non-zero status on the `source`.
    _INIT_EXPORT_LOOP = (
        'for d in "$HOME/.sdkman/candidates/"*/current/bin; do '
        'if [ -d "$d" ]; then export PATH="$d:$PATH"; fi; done'
    )

    def __init__(self, tmp_path: Path, tag: str, faithful: bool = False) -> None:
        self.root = tmp_path / tag
        self.bin = self.root / "bin"
        self.userbin = self.root / "userbin"
        self.home = self.root / "home"
        self.staging = self.root / "staging"
        self.sdkman = self.home / ".sdkman"
        self.faithful = faithful
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
            "printf '%s\\n' '" + self._INIT_EXPORT_LOOP + "' "
            '>> "$SDKMAN_DIR/bin/sdkman-init.sh"\n'
            "exit 0\n",
            encoding="utf-8",
        )

        self._write_su_stub()
        self.set_curl("empty")
        self.set_sdk({})

    # -- stubs ---------------------------------------------------------------
    def _write_su_stub(self) -> None:
        """`su - <user> -s /bin/bash (-c|-lc) <cmd>` stub.

        Reproduces the observable properties of util-linux `su` these
        installers rely on: (1) the command runs with the TARGET USER's HOME,
        (2) su's exit status is the command's exit status. PATH is rebuilt
        from scratch (never inherited) so nothing from the host can leak in.

        Whether the LOGIN shell already has SDKMAN on PATH is the whole
        false-positive story, so the stub has two modes:

        * ``faithful=False`` (legacy default): the login branch sources
          ~/.sdkman/bin/sdkman-init.sh, modelling a user profile chain that
          exports SDKMAN. That chain does NOT exist during a build: the
          /etc/profile.d hook is written by the RUN after the feature loop
          (dockerfile_template.j2:240-243). The mode is kept because the
          java-sdkman happy-path stdout-parity proofs run the PRE-FIX
          installer, whose probe depends on it.
        * ``faithful=True``: the login branch sources NOTHING. A bare
          ``command -v`` probe then fails exactly as it does in the real
          image at feature-loop time; only a probe that sources the init
          script itself can pass.
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
        )
        if not self.faithful:
            body += (
                "init='" + str(self.home) + "/.sdkman/bin/sdkman-init.sh'\n"
                'if [ "$login" = 1 ] && [ -s "$init" ]; then\n'
                "  source \"$init\" || true\n"
                "fi\n"
            )
        body += "exec '" + BASH + "' -c \"$cmd\"\n"
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
        their documented fallback branch. A materialised binary lands at
        ``$HOME/.sdkman/candidates/<candidate>/current/bin/<binary>`` — the
        path the real SDKMAN uses and the path the consumer probes verify.
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
                bindir = self.sdkman / "candidates" / candidate / "current" / "bin"
                target = str(bindir / produce)
                lines.append('      mkdir -p "' + str(bindir) + '"')
                lines.append('      cp "' + str(self.staging / produce) + '" "' + target + '"')
                lines.append('      chmod 755 "' + target + '"')
            lines.append("      exit " + str(rc))
            lines.append("      ;;")
        lines += ["    *) exit 0 ;;", "    esac", "  fi", "exit 0", ""]
        _write_exec(self.userbin / "sdk", "\n".join(lines))

    def preinstall_sdkman(self, *, exposes_sdk: bool = True) -> Path:
        """Write the init artefact by hand (partial/complete install states).

        A complete init exports the shim dir (the stub ``sdk``) plus the
        per-candidate current/bin loop the real sdkman-init.sh runs: the
        candidates become reachable ONLY through sourcing the init, never
        through the login shell itself.
        """
        init = self.sdkman / "bin" / "sdkman-init.sh"
        init.parent.mkdir(parents=True, exist_ok=True)
        if exposes_sdk:
            init.write_text(
                'export PATH="' + str(self.userbin) + ':$PATH"\n'
                + self._INIT_EXPORT_LOOP
                + "\n",
                encoding="utf-8",
            )
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


def _false_positive_form(feature: str, dest_dir: Path) -> Path:
    """The 8da2bd8 revision of a consumer installer: its verify probe is a
    bare `command -v <bin>` inside a single-quoted login-shell command — the
    form that could only pass where the login shell already sources the init
    script, i.e. never during a real build. The marker below is absent from
    the converted installer (whose probe string starts with `set +u`), so a
    wrong-tree fetch fails loudly instead of silently testing nothing."""
    proc = subprocess.run(
        ["git", "-C", str(REPO), "show", f"{FALSE_POSITIVE_REF}:features/{feature}/install.sh"],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0 or "-lc 'command -v " not in proc.stdout:
        pytest.skip(
            f"false-positive installer not retrievable at {FALSE_POSITIVE_REF} "
            "(shallow clone, or the probe shape changed and the guard must be re-pinned)"
        )
    path = dest_dir / f"install_fp_{feature}.sh"
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
    # java-gradle REMOVED from this suite: it no longer installs through the
    # SDKMAN transport (pinned digest-verified toolcache mirror via
    # download_direct). Its fail-loud contract lives in
    # tests/test_java_gradle_is_mirrored.py.
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
        """exit 6: the probe now checks the artefact path itself, so the
        message names the exact missing file instead of ASSERTING it is
        missing (the 8da2bd8 prose no code verified). Producer attribution
        stays where it was verified — the FH_*_INSTALL_FAILED paths, pinned
        by the test above, which still name java-sdkman."""
        spec = _CONSUMERS[feature]
        sb = _Sandbox(tmp_path, f"{feature}-no-bin")
        sb.preinstall_sdkman()
        sb.set_sdk({spec["candidate"]: (0, None)})  # exit 0, materialises nothing

        proc = sb.run(REPO / "features" / feature / "install.sh", spec["env"])

        assert proc.returncode == 1, proc.stdout
        assert spec["verify_token"] in proc.stderr
        assert f"candidates/{spec['candidate']}/current/bin/{spec['binary']}" in proc.stderr
        assert "missing" in proc.stderr  # the exit-6 cause, not the generic one
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


class TestFaithfulEnvironment:
    """The 8da2bd8 false-positive regression guard — the test that was missing.

    8da2bd8 verified its consumers with `su - <user> -lc 'command -v <bin>'`.
    That probe is un-satisfiable during a build: `su -` resets PATH through
    /etc/profile, and the /etc/profile.d hook that would export the SDKMAN
    candidate bins is written by the RUN that comes AFTER the feature loop
    (solen-cli/solen/generators/dockerfile_template.j2:240-243). It aborted
    deterministically 3/3 on healthy installs and blocked trunk.

    The legacy harness could not see this because its `su` stub's login
    branch sources the fake init — modelling the profile chain that only
    exists post-:243. Faithful mode removes that synthetic sourcing. The
    two tests below pin BOTH directions, so neither the guard nor the mode
    can go vacuous silently: the defective probe passes in the synthetic
    world (the harness flaw, made visible) and fails in the faithful one,
    where the converted probe passes.
    """

    @pytest.mark.parametrize("feature", sorted(_CONSUMERS))
    def test_synthetic_sourcing_is_what_hid_the_false_positive(self, tmp_path, feature):
        """The 8da2bd8 probe passes a healthy install ONLY because the legacy
        su stub sources the init in its login branch. If this test ever
        fails, the synthetic mode stopped modelling what it is meant to
        model and the discrimination below proves nothing."""
        spec = _CONSUMERS[feature]
        sb = _Sandbox(tmp_path, f"{feature}-synthetic-fp")
        sb.preinstall_sdkman()
        sb.set_sdk({spec["candidate"]: (0, spec["binary"])})

        proc = sb.run(_false_positive_form(feature, sb.root), spec["env"])
        assert proc.returncode == 0, (
            "the synthetic (legacy) su mode no longer lets the 8da2bd8 bare-login "
            f"probe pass a healthy install (rc={proc.returncode}); the harness "
            "modelling changed and the faithful guard needs re-checking"
        )
        assert f"{feature}: installation successful" in proc.stdout

    @pytest.mark.parametrize("feature", sorted(_CONSUMERS))
    def test_healthy_install_fails_the_old_probe_and_passes_the_new_one(
        self, tmp_path, feature
    ):
        """DECISIVE: one healthy install (sdk exits 0 and materialises the
        binary), faithful environment (login shell without SDKMAN, as during
        the real feature loop). The 8da2bd8 probe aborts — the false positive
        that blocked trunk — while the init-sourcing probe exits 0."""
        spec = _CONSUMERS[feature]
        sb = _Sandbox(tmp_path, f"{feature}-faithful-ok", faithful=True)
        sb.preinstall_sdkman()
        sb.set_sdk({spec["candidate"]: (0, spec["binary"])})

        old = sb.run(_false_positive_form(feature, sb.root), spec["env"])
        assert old.returncode == 1, (
            "the faithful environment no longer breaks the 8da2bd8 bare-login "
            "probe — the guard has gone vacuous (the su stub must NOT source "
            "the init in its login branch)"
        )
        assert spec["verify_token"] in old.stderr
        assert f"{feature}: done" not in old.stdout

        new = sb.run(REPO / "features" / feature / "install.sh", spec["env"])
        assert new.returncode == 0, (
            "the init-sourcing probe failed on a healthy install in the "
            f"faithful environment: rc={new.returncode} stderr={new.stderr!r}"
        )
        assert f"{feature}: installation successful" in new.stdout
        assert f"{feature}: done" in new.stdout
        assert spec["verify_token"] not in new.stderr

    def test_faithful_artefact_missing_names_the_exact_file(self, tmp_path):
        """exit 6 in the faithful environment: sdk exits 0 but the candidate
        current/bin/mvn is never materialised."""
        sb = _Sandbox(tmp_path, "maven-faithful-no-artefact", faithful=True)
        sb.preinstall_sdkman()
        sb.set_sdk({"maven": (0, None)})

        proc = sb.run(REPO / "features" / "java-maven" / "install.sh")

        assert proc.returncode == 1, proc.stdout
        assert "FH_JAVA_MAVEN_NOT_AVAILABLE" in proc.stderr
        assert "candidates/maven/current/bin/mvn" in proc.stderr
        assert "java-maven: done" not in proc.stdout

    def test_faithful_init_missing_is_exit_3_cause(self, tmp_path):
        """exit 3: the target user has no sdkman-init.sh at all. The probe is
        reached by making `sdk` resolvable to the installer process — the
        real-image analogue is root's own SDKMAN present while jovyan's is
        absent — so the 'Please include java-sdkman' early abort is not the
        outcome under test."""
        sb = _Sandbox(tmp_path, "maven-faithful-no-init", faithful=True)
        sb.set_sdk({"maven": (0, None)})
        (sb.bin / "sdk").symlink_to(sb.userbin / "sdk")  # bypass the early abort

        proc = sb.run(REPO / "features" / "java-maven" / "install.sh")

        assert proc.returncode == 1, proc.stdout
        assert "FH_JAVA_MAVEN_NOT_AVAILABLE" in proc.stderr
        assert "no init artefact" in proc.stderr
        assert "Please include java-sdkman feature first" not in proc.stderr
        assert "java-maven: done" not in proc.stdout

    def test_faithful_init_unsourceable_is_exit_4_cause(self, tmp_path):
        """exit 4: the init exists and is non-empty, but sourcing it fails
        (corrupt content). Verified earlier in this session: bash `source` on
        a syntax-error file returns non-zero without killing the sourcing
        shell, so `|| exit 4` is the reachable branch."""
        sb = _Sandbox(tmp_path, "maven-faithful-bad-init", faithful=True)
        sb.set_sdk({"maven": (0, None)})
        (sb.bin / "sdk").symlink_to(sb.userbin / "sdk")  # bypass the early abort
        init = sb.sdkman / "bin" / "sdkman-init.sh"
        init.parent.mkdir(parents=True, exist_ok=True)
        init.write_text("bogus ((\n", encoding="utf-8")  # syntax error on source

        proc = sb.run(REPO / "features" / "java-maven" / "install.sh")

        assert proc.returncode == 1, proc.stdout
        assert "FH_JAVA_MAVEN_NOT_AVAILABLE" in proc.stderr
        assert "could not be sourced" in proc.stderr
        assert "java-maven: done" not in proc.stdout


class TestConsumerContractPreserved:
    """Change 3/4: nothing that used to be a correct early abort got softer,
    and no supported configuration became a hard failure."""

    # java-gradle dropped: it has no SDKMAN-absent abort any more (see
    # tests/test_java_gradle_is_mirrored.py for its guards).
    @pytest.mark.parametrize("feature", ["java-jdk", "java-maven"])
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
