"""Regression tests for the graalvm / zsh-config fail-loud contract: the two
features that still published images advertising tools they did not contain.

graalvm (features/graalvm/install.sh, pre-fd0f231 form)::

    DIST_ID="${SDKMAN_GRAALVM_IDENTIFIER:-graalvm-ce}"
    CAND="${DIST_ID}-${GRAALVM_VERSION}"          # -> graalvm-ce-22.3.1
    sdk install java "${CAND}" || sdk install java "${DIST_ID}" || true

SDKMAN's ``java`` candidate identifies GraalVM as ``<version>-graalce`` /
``<version>-graal``; neither ``graalvm-ce-22.3.1`` nor bare ``graalvm-ce``
exists in the catalog on any platform, so the install deterministically hit
SDKMAN's "not a valid version" path and the trailing ``|| true`` discarded the
status. Measured consequence: ``verify-published`` (job 117502438116) died on
``run-check-env.sh: line 30: java: command not found`` -- lang-java-graal is
the only java profile without java-jdk and java-sdkman installs no java
candidate, so the image shipped without java while feature.json advertised
``java``, ``javac`` and ``graalvm``.

zsh-config (features/zsh-config/install.sh, pre-fd0f231 form) double-masked
starship: the ``curl | sh`` pipeline ended in ``|| true`` *and* the ``su`` that
ran it ended in ``|| true``, while the feature's own postInstallCheck asserts
``test -x /home/jovyan/.local/bin/starship`` -- a check that failed on 6 tags.
Its ``if [ -d "${HOME_DIR}" ]`` also had no ``else``, so a missing home skipped
the entire configuration block silently.

These tests run the REAL shipped installers with ``su``, ``curl``, ``git``,
``sdk``, ``dpkg``, ``download_direct`` and ``fh_resolve_version`` stubbed and pin:

  1. graalvm: an uninstallable candidate aborts at the producer (rc 1,
     FH_GRAALVM_INSTALL_FAILED, naming the resolved id);
  2. graalvm: ``sdk install`` exiting 0 while materialising nothing is caught
     by the artefact post-condition (FH_GRAALVM_NOT_AVAILABLE, naming
     $HOME/.sdkman/candidates/java/current/bin/java);
  3. graalvm: a healthy install passes (rc 0) through the init-sourcing probe,
     and a legacy GRAALVM_VERSION is ignored loudly instead of being composed
     into a dead identifier;
  4. graalvm: a java that is present but is not a GraalVM runtime is fatal
     (the feature advertises GraalVM, not merely java);
  5. zsh-config: a failed download_direct fetch of the pinned archive is
     fatal (rc 1, FH_STARSHIP_INSTALL_FAILED, naming the v-pinned GitHub
     asset) and installs nothing;
  6. zsh-config: a download_direct that exits 0 having written no binary is
     fatal -- what the post-condition buys that rc checks alone cannot; an
     unresolved pin likewise aborts BEFORE any fetch (FH_VERSION_UNRESOLVED);
  7. zsh-config: the healthy path exits 0 with the binary present;
  8. RED proofs: the fd0f231 forms of both installers exit 0 on the exact
     inputs above, so these assertions discriminate the fix.

Hermeticity: PATH is the stub directory ALONE (the lesson recorded in
tests/test_kotlin_install_failure_is_loud.py), no network, everything under
pytest's tmp_path. The ``su`` stub runs in FAITHFUL mode only: the login shell
sources nothing, because /etc/profile.d/solen.sh -- the hook that would export
SDKMAN -- is written by the RUN that follows the feature loop
(solen-cli/solen/generators/dockerfile_template.j2:240-243). Only a probe that
sources sdkman-init.sh itself can pass here, which is exactly the property
c5af458 established.
"""

import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
GRAALVM_SH = REPO / "features" / "graalvm" / "install.sh"
ZSH_CONFIG_SH = REPO / "features" / "zsh-config" / "install.sh"

# Last revision whose installers still masked these failures with `|| true`.
# Pinned to a SHA, not HEAD, so the RED proofs keep working once the fix is
# committed -- same convention as tests/test_java_sdkman_install_failure_is_loud.py.
OLD_FORM_REF = "fd0f231"

GRAAL_INSTALL_TOKEN = "FH_GRAALVM_INSTALL_FAILED"
GRAAL_PROBE_TOKEN = "FH_GRAALVM_NOT_AVAILABLE"
STARSHIP_TOKEN = "FH_STARSHIP_INSTALL_FAILED"

# The correct Community id both catalog arches carry (verified against
# https://api.sdkman.io/2/candidates/java/linux{arm64,x64}/versions/list).
CE_ID = "25.4.4.1+1-graalce"

# --- bash >= 4 resolution (macOS /bin/bash is 3.2) --------------------------
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
        "no bash >= 4 found; the graalvm/zsh-config installers require bash 4+",
        allow_module_level=True,
    )

# Everything the two installers and their stubbed children invoke besides
# bash builtins. Staged by absolute path so the scrubbed PATH stays closed.
_PLUMBING = ("cat", "chmod", "chown", "cp", "grep", "head", "mkdir", "rm", "sed", "sh")

_GRAAL_JAVA = (
    "echo 'openjdk version \"25.0.2\" 2025-07-15' >&2\n"
    "echo 'OpenJDK Runtime Environment GraalVM CE 25.4.4.1+1' >&2\n"
    "exit 0\n"
)
_PLAIN_JAVA = (
    "echo 'openjdk version \"25.0.2\" 2025-07-15' >&2\n"
    "echo 'OpenJDK Runtime Environment (Temurin)+10' >&2\n"
    "exit 0\n"
)
_STARSHIP_BOOTSTRAP = (
    "#!/bin/sh\n"
    'mkdir -p "$HOME/.local/bin"\n'
    "printf '#!%s\\necho starship 1.22.1\\nexit 0\\n' '" + BASH + "' > \"$HOME/.local/bin/starship\"\n"
    'chmod 755 "$HOME/.local/bin/starship"\n'
    "exit 0\n"
)


def _write_exec(path: Path, body: str) -> None:
    # Absolute interpreter, never `#!/usr/bin/env bash`: the sandbox PATH is
    # scrubbed, so an env-shebang stub could not find bash.
    path.write_text("#!" + BASH + "\n" + body, encoding="utf-8")
    path.chmod(0o755)


class _Sandbox:
    """Fake host for one installer run (same shape as the java-sdkman harness).

    * ``bin``     -- the ONLY PATH entry of the installer process;
    * ``userbin`` -- the shim dir the fake ``sdkman-init.sh`` exports (stub ``sdk``);
    * ``home``    -- fake ``$HOME`` for the installer AND for the stubbed ``su``
                     login shell, and the ``HOME_DIR`` given to zsh-config, so
                     the producer's post-condition and the user's install target
                     are the same directory;
    * ``staging`` -- binaries the stub ``sdk`` materialises.
    """

    _INIT_EXPORT_LOOP = (
        'for d in "$HOME/.sdkman/candidates/"*/current/bin; do '
        'if [ -d "$d" ]; then export PATH="$d:$PATH"; fi; done'
    )

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

        for name, body in (("java-graal", _GRAAL_JAVA), ("java-plain", _PLAIN_JAVA)):
            staged = self.staging / name
            staged.write_text("#!" + BASH + "\n" + body, encoding="utf-8")
            staged.chmod(0o755)

        # Faithful `su`: PATH rebuilt from scratch, HOME the target user's,
        # exit status the command's, and the login shell sources NOTHING.
        _write_exec(
            self.bin / "su",
            "# Stub su.\n"
            'cmd="${@: -1}"\n'
            "export HOME='" + str(self.home) + "'\n"
            "export PATH='" + str(self.bin) + "'\n"
            "unset SDKMAN_DIR\n"
            "exec '" + BASH + "' -c \"$cmd\"\n",
        )
        # Keeps zsh-config off its `apt_install git` branch (no apt here).
        _write_exec(self.bin / "git", "# Stub git.\nexit 0\n")
        # starship mirror stack (zsh-config, post-6ffe215): the installer maps
        # dpkg's amd64 -> x86_64 for the release asset; the stub fixes amd64.
        _write_exec(self.bin / "dpkg", "# Stub dpkg.\necho amd64\n")
        # Version resolution without the prebaked helpers: a PATH executable
        # answers `command -v fh_resolve_version` exactly like the sourced
        # function would, extracting .tools[$1] from the repo SoT (read-only).
        _write_exec(
            self.bin / "fh_resolve_version",
            "# Stub fh_resolve_version (read-only on versions.json).\n"
            'sed -n "s/.*\\"$1\\": \\"\\([^\\"]*\\)\\".*/\\1/p" "'
            + str(REPO / "versions.json") + '" | head -1\n'
            "exit 0\n",
        )
        # `sh` is staged from the system; `curl`/`sdk`/`download_direct` are
        # mode-configured below.
        self.set_curl("empty")
        self.set_sdk("noop")
        self.set_download_direct("noop")

        init = self.sdkman / "bin" / "sdkman-init.sh"
        init.parent.mkdir(parents=True, exist_ok=True)
        init.write_text(
            'export PATH="' + str(self.userbin) + ':$PATH"\n' + self._INIT_EXPORT_LOOP + "\n",
            encoding="utf-8",
        )

    # -- stubs ---------------------------------------------------------------
    def set_curl(self, mode: str) -> None:
        """``fail6``: the transient egress error; ``empty``: serves nothing (exit
        0, which pipefail alone cannot catch); ``install``: the working installer."""
        if mode == "fail6":
            body = (
                "# Stub curl: unresolvable host.\n"
                "echo 'curl: (6) Could not resolve host: starship.rs' >&2\n"
                "exit 6\n"
            )
        elif mode == "empty":
            body = "# Stub curl: succeeds, serves nothing.\nexit 0\n"
        elif mode == "install":
            boot = self.root / "starship-install.sh"
            boot.write_text(_STARSHIP_BOOTSTRAP, encoding="utf-8")
            body = "# Stub curl: serves the starship installer on stdout.\ncat '" + str(boot) + "'\nexit 0\n"
        else:  # pragma: no cover - harness misuse
            raise ValueError(f"unknown curl mode {mode!r}")
        _write_exec(self.bin / "curl", body)

    def set_download_direct(self, mode: str) -> None:
        """``fail``: egress dies mid-fetch (the curl (35) class that killed run
        39129344307), rc 35, writes nothing; ``noop``: exits 0 having written
        nothing -- the exact shape a green rc cannot prove; ``ok``: materialises
        the executable at the installer's requested dir ($4), like the real
        helper does with extract=true."""
        lines = [
            "# Stub download_direct. Never touches the network.",
            'echo "download_direct-stub: $*" >&2',
        ]
        if mode == "fail":
            lines += [
                "echo 'curl: (35) Recv failure: Connection reset by peer' >&2",
                "exit 35",
            ]
        elif mode == "noop":
            lines += ["exit 0"]
        elif mode == "ok":
            lines += [
                'mkdir -p "$4"',
                "printf '#!/bin/sh\\necho starship 1.27.0\\nexit 0\\n' > \"$4/starship\"",
                'chmod 755 "$4/starship"',
            ]
        else:  # pragma: no cover - harness misuse
            raise ValueError(f"unknown download_direct mode {mode!r}")
        lines += ["exit 0", ""]
        _write_exec(self.bin / "download_direct", "\n".join(lines))

    def set_sdk(self, mode: str) -> None:
        """``reject``: SDKMAN's 'not a valid version' path (exit 1, writes
        nothing); ``noop``: exits 0 having materialised nothing; ``ok`` /
        ``ok_plain``: installs a GraalVM / a non-GraalVM java at the real
        SDKMAN candidate path."""
        bindir = self.sdkman / "candidates" / "java" / "current" / "bin"
        lines = [
            "# Stub sdk. Never touches the network.",
            'echo "sdk-stub: $*" >&2',
            'if [ "${1:-}" = "install" ] && [ "${2:-}" = "java" ]; then',
        ]
        if mode == "reject":
            lines += [
                "  echo '!  is not a valid version.' >&2",
                "  exit 1",
            ]
        elif mode == "noop":
            lines += ["  exit 0"]
        elif mode in ("ok", "ok_plain"):
            staged = "java-graal" if mode == "ok" else "java-plain"
            lines += [
                '  mkdir -p "' + str(bindir) + '"',
                '  cp "' + str(self.staging / staged) + '" "' + str(bindir / "java") + '"',
                '  chmod 755 "' + str(bindir / "java") + '"',
                "  exit 0",
            ]
        else:  # pragma: no cover - harness misuse
            raise ValueError(f"unknown sdk mode {mode!r}")
        lines += ["fi", "exit 0", ""]
        _write_exec(self.userbin / "sdk", "\n".join(lines))

    # -- execution -----------------------------------------------------------
    def run(self, installer: Path, env_extra: dict | None = None):
        env = {
            "PATH": str(self.bin),
            "HOME": str(self.home),
            "TMPDIR": str(self.root),
            "NB_USER": "jovyan",
            "HOME_DIR": str(self.home),
        }
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


def _old_form(feature: str, dest_dir: Path, *, home_dir_patch: bool = False) -> Path:
    """The fd0f231 installer, straight from git.

    ``home_dir_patch`` is required for the zsh-config RED proof ONLY: the old
    form hardcodes ``HOME_DIR="/home/${NB_USER}"``, which cannot exist in a
    user-walled sandbox; without the (mechanical, already-shipped-form)
    override the block would be skipped for the wrong reason instead of
    exercising its ``|| true`` masking. The patch asserts it applied, so a
    changed tree fails loudly instead of silently testing nothing.
    """
    proc = subprocess.run(
        ["git", "-C", str(REPO), "show", f"{OLD_FORM_REF}:features/{feature}/install.sh"],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0 or "|| true" not in proc.stdout:
        pytest.skip(f"pre-fix installer not retrievable at {OLD_FORM_REF} (shallow clone?)")
    text = proc.stdout
    if home_dir_patch:
        old_line = 'HOME_DIR="/home/${NB_USER}"'
        if old_line not in text:
            pytest.skip(f"{OLD_FORM_REF} zsh-config no longer hardcodes HOME_DIR (guard must be re-pinned)")
        text = text.replace(old_line, 'HOME_DIR="${HOME_DIR:-/home/${NB_USER}}"')
    path = dest_dir / f"install_old_{feature.replace('-', '_')}.sh"
    path.write_text(text, encoding="utf-8")
    path.chmod(0o755)
    return path


class TestGraalvmFailsLoud:
    """The candidate id must resolve, and a non-install must abort at the producer."""

    def test_uninstallable_candidate_aborts_at_the_producer(self, tmp_path):
        sbx = _Sandbox(tmp_path, "reject")
        sbx.set_sdk("reject")
        res = sbx.run(GRAALVM_SH)
        assert res.returncode == 1, res.stdout + res.stderr
        assert GRAAL_INSTALL_TOKEN in res.stderr
        assert CE_ID in res.stderr
        assert not (sbx.sdkman / "candidates" / "java" / "current" / "bin" / "java").exists()

    def test_exit_zero_installing_nothing_is_fatal(self, tmp_path):
        """`sdk install` returning 0 with no candidate is exactly what the
        removed `|| true` chain could hide; only the artefact gate catches it."""
        sbx = _Sandbox(tmp_path, "noop")
        sbx.set_sdk("noop")
        res = sbx.run(GRAALVM_SH)
        assert res.returncode == 1, res.stdout + res.stderr
        assert GRAAL_PROBE_TOKEN in res.stderr
        assert "$HOME/.sdkman/candidates/java/current/bin/java" in res.stderr

    def test_healthy_install_exits_zero_and_flags_legacy_version(self, tmp_path):
        sbx = _Sandbox(tmp_path, "healthy")
        sbx.set_sdk("ok")
        # The stale profiles/matrix/languages.yaml value, verbatim.
        res = sbx.run(GRAALVM_SH, {"GRAALVM_VERSION": "22.3.1"})
        assert res.returncode == 0, res.stdout + res.stderr
        assert "ignoring legacy GRAALVM_VERSION='22.3.1'" in res.stderr
        assert f"sdk install java {CE_ID}" in res.stdout
        assert (sbx.sdkman / "candidates" / "java" / "current" / "bin" / "java").exists()

    def test_java_that_is_not_graalvm_is_fatal(self, tmp_path):
        sbx = _Sandbox(tmp_path, "notgraal")
        sbx.set_sdk("ok_plain")
        res = sbx.run(GRAALVM_SH)
        assert res.returncode == 1, res.stdout + res.stderr
        assert GRAAL_PROBE_TOKEN in res.stderr
        assert "does not report a GraalVM runtime" in res.stderr

    def test_red_proof_pre_fix_installer_exited_zero(self, tmp_path):
        """fd0f231 returned 0 on the two broken guarantees above."""
        for mode in ("reject", "noop"):
            sbx = _Sandbox(tmp_path, f"red-{mode}")
            sbx.set_sdk(mode)
            old = _old_form("graalvm", tmp_path)
            res = sbx.run(old)
            assert res.returncode == 0, f"pre-fix {mode} case unexpectedly failed:\n{res.stderr}"
            assert "graalvm: done" in res.stdout
            assert not (sbx.sdkman / "candidates" / "java" / "current" / "bin" / "java").exists()


class TestStarshipFailsLoud:
    """starship is this feature's own contract check; it may not no-op quietly.
    Post-6ffe215 the fetch is the pinned, digest-verified download_direct call
    (toolcache mirror); the fatality contract is unchanged."""

    def test_egress_failure_aborts_at_the_producer(self, tmp_path):
        sbx = _Sandbox(tmp_path, "ss-fail")
        sbx.set_download_direct("fail")
        res = sbx.run(ZSH_CONFIG_SH)
        assert res.returncode == 1, res.stdout + res.stderr
        assert STARSHIP_TOKEN in res.stderr
        assert "starship-x86_64-unknown-linux-musl.tar.gz" in res.stderr
        assert "releases/download/v" in res.stderr
        assert not (sbx.home / ".local" / "bin" / "starship").exists()

    def test_exit_zero_installing_nothing_is_fatal(self, tmp_path):
        """download_direct exits 0 having written nothing -> rc checks alone
        see green. Only the post-condition catches this shape."""
        sbx = _Sandbox(tmp_path, "ss-empty")
        sbx.set_download_direct("noop")
        res = sbx.run(ZSH_CONFIG_SH)
        assert res.returncode == 1, res.stdout + res.stderr
        assert STARSHIP_TOKEN in res.stderr
        assert str(sbx.home / ".local" / "bin" / "starship") in res.stderr

    def test_unresolved_pin_aborts_before_any_fetch(self, tmp_path):
        """starship is checksum-pinned: no fh_resolve_version answer and no
        artefacts/versions.json must abort with FH_VERSION_UNRESOLVED, never
        fall back to upstream 'latest' and never reach download_direct."""
        sbx = _Sandbox(tmp_path, "ss-nopin")
        _write_exec(sbx.bin / "fh_resolve_version", "# Stub: resolves nothing.\nexit 0\n")
        sbx.set_download_direct("fail")  # if reached, the test would see its token
        res = sbx.run(ZSH_CONFIG_SH)
        assert res.returncode == 1, res.stdout + res.stderr
        assert "FH_VERSION_UNRESOLVED" in res.stderr
        assert STARSHIP_TOKEN not in res.stderr

    def test_healthy_install_exits_zero(self, tmp_path):
        sbx = _Sandbox(tmp_path, "ss-ok")
        sbx.set_download_direct("ok")
        res = sbx.run(ZSH_CONFIG_SH)
        assert res.returncode == 0, res.stdout + res.stderr
        assert (sbx.home / ".local" / "bin" / "starship").is_file()
        assert "zsh-config: done" in res.stdout

    def test_missing_home_is_fatal_not_silently_skipped(self, tmp_path):
        sbx = _Sandbox(tmp_path, "ss-nohome")
        sbx.set_curl("install")
        # The path must be UNCREATEABLE, not merely absent: the installer's own
        # user-dir bootstrap runs `mkdir -p "${HOME_DIR}/.local/bin"`, so a plain
        # missing directory would exist by the time the `-d` gate is evaluated and
        # the branch under test would never be reached. A regular file as the
        # parent makes that mkdir fail for good.
        blocker = tmp_path / "ss-nohome" / "not-a-directory"
        blocker.write_text("stop", encoding="utf-8")
        missing = blocker / "absent-home"
        res = sbx.run(ZSH_CONFIG_SH, {"HOME_DIR": str(missing)})
        assert res.returncode == 1, res.stdout + res.stderr
        assert "FH_ZSH_HOME_MISSING" in res.stderr
        assert str(missing) in res.stderr
        assert "container-user" in res.stderr

    def test_red_proof_pre_fix_installer_exited_zero(self, tmp_path):
        """fd0f231 exited 0 with no starship on the exact failing inputs above."""
        for mode in ("fail6", "empty"):
            sbx = _Sandbox(tmp_path, f"ss-red-{mode}")
            sbx.set_curl(mode)
            old = _old_form("zsh-config", tmp_path, home_dir_patch=True)
            res = sbx.run(old)
            assert res.returncode == 0, f"pre-fix {mode} case unexpectedly failed:\n{res.stderr}"
            assert "zsh-config: done" in res.stdout
            assert not (sbx.home / ".local" / "bin" / "starship").exists()


class TestGraalProfilePassesAResolvableId:
    """profiles/matrix/languages.yaml must hand graalvm a catalog id.

    The installer's legacy-numbering warning is a guard, not a plan: a profile
    that keeps passing `22.3.1` is only correct because the feature ignores it,
    which leaves the trap armed for the next reader and puts a permanent warning
    on every graal build. These pin the corrected value and prove the resolution
    logic takes it verbatim.
    """

    def test_lang_java_graal_selects_a_graalce_candidate(self):
        text = (REPO / "profiles" / "matrix" / "languages.yaml").read_text(encoding="utf-8")
        assert "GRAALVM_VERSION: 22.3.1" not in text
        assert f"GRAALVM_VERSION: {CE_ID}" in text

    def test_resolved_candidate_is_taken_verbatim(self, tmp_path):
        sbx = _Sandbox(tmp_path, "matrix-id")
        sbx.set_sdk("ok")
        res = sbx.run(GRAALVM_SH, {"GRAALVM_VERSION": CE_ID})
        assert res.returncode == 0, res.stdout + res.stderr
        assert "ignoring legacy" not in res.stderr
        assert f"sdk install java {CE_ID}" in res.stdout
