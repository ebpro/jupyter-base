"""Behavioural tests for the kotlin-jupyter kernel branch of features/kotlin/install.sh.

The kernel stage (``INSTALL_KOTLIN_KERNEL=true``) performs a build-time fetch
of the pinned ``kotlin_jupyter_kernel`` wheel from files.pythonhosted.org,
verifies it against the repo-root ``checksums.json`` (``tools.kotlin-jupyter``)
and installs it with the notebook stack's own interpreter using
``pip install --no-index --no-deps``.

These tests run the *real* installer body inside a PATH sandbox with:

  * a stub ``curl`` that counts attempts and writes controlled content;
  * a stub ``conda/bin/python`` that emulates ``pip install`` by materialising
    ``share/jupyter/kernels/kotlin/kernel.json`` plus the ``run_kotlin_kernel``
    payload (jars/, config/jar_args.json, main jar) and records every
    invocation (including ``$0``, the exact interpreter path used).

No container, no network, no real wheel. The load-bearing assertions are:

  (a) fetch failure -> loud non-zero exit naming wheel/version/digest/consumer,
      exactly 3 curl attempts;
  (b) checksum mismatch -> non-zero exit after exactly 1 attempt and pip is
      NEVER invoked (a digest failure that could be retried into a pass would
      be a P1);
  (c) happy path -> ``--no-index --no-deps`` flags and the exact interpreter;
  (d) false gate -> stdout byte-identical to the HEAD (pre-kernel) installer;
  (e) ``True``/``TRUE``/``true`` all enter the gate (${VAR,,} normalisation);
  (f) second invocation skips the fetch (idempotency).

The digest-vs-PyPI ground truth is covered statically in
tests/test_kotlin_kernel_contract.py (pinned literal + live-verified notes).
"""

import hashlib
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
INSTALL_SH = REPO / "features" / "kotlin" / "install.sh"

# Revision whose kernel branch was the "please provide ARTIFACTS or release
# URL" placeholder. Pinned by SHA (not HEAD) so the byte-identity test keeps
# working after the kernel installer is committed.
PRE_KERNEL_REF = "2cb1fbf"

TEST_VERSION = "9.9.9-test"
WHEEL_NAME = f"kotlin_jupyter_kernel-{TEST_VERSION}-py3-none-any.whl"
WHEEL_CONTENT = b"KOTLIN-JUPYTER-KERNEL-STUB-WHEEL"
WHEEL_SHA = hashlib.sha256(WHEEL_CONTENT).hexdigest()
TEST_URL = f"https://example.invalid/{WHEEL_NAME}"

# The installer uses ${VAR,,} (bash 4+); macOS ships /bin/bash 3.2. Same
# resolution strategy as tests/test_kotlin_boolean_gates.py.
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


def _write_exec(path: Path, body: str) -> None:
    path.write_text("#!/bin/bash\n" + body + "\n", encoding="utf-8")
    path.chmod(0o755)


_CURL_STUB = r"""
log="${CURL_LOG:?}"
touch "$log"
n=$(( $(wc -l < "$log" | tr -d ' ') + 1 ))
url="${!#}"                      # last argument
echo "$n $url" >> "$log"
fail_until="${CURL_FAIL_UNTIL:-1}"
if [ "$n" -lt "$fail_until" ]; then
  exit 22                        # transient HTTP error, like curl 22 on 4xx/5xx
fi
# find the argument after -o (the --connect-timeout/--max-time values must not
# be mistaken for it)
dest=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then dest="$a"; fi
  prev="$a"
done
if [ -n "$dest" ]; then
  printf '%s' "${WHEEL_CONTENT.stub}" > "$dest"
fi
exit "${CURL_EXIT:-0}"
"""

_PYTHON_STUB = r"""
conda="${CONDA_DIR:?}"
site="$conda/lib/python/site-packages"
spec="$conda/share/jupyter/kernels/kotlin"
mkdir -p "$(dirname "${PIP_LOG:-/dev/null/x}")" 2>/dev/null || true
case "$1" in
  -c)
    # idempotency probe: `import run_kotlin_kernel`
    if [ -f "$spec/kernel.json" ] && [ -f "$site/run_kotlin_kernel/__init__.py" ]; then
      exit 0
    fi
    exit 1
    ;;
  -m)
    echo "INTERPRETER $0 :: $*" >> "${PIP_LOG:?}"
    if printf '%s\n' "$*" | grep -q -- "-m pip install --no-index --no-deps "; then
      wheel="$(printf '%s\n' "$*" | awk '{print $NF}')"
      [ -f "$wheel" ] || exit 2          # must install the verified local wheel
      mkdir -p "$spec" "$site/run_kotlin_kernel/jars" "$site/run_kotlin_kernel/config"
      printf '%s\n' '{"argv":["python","-m","run_kotlin_kernel","{connection_file}"],"display_name":"Kotlin","language":"kotlin"}' > "$spec/kernel.json"
      printf '%s\n' '{"mainJar": "kotlin-jupyter-kernel-all.jar"}' > "$site/run_kotlin_kernel/config/jar_args.json"
      : > "$site/run_kotlin_kernel/jars/kotlin-jupyter-kernel-all.jar"
      : > "$site/run_kotlin_kernel/__init__.py"
      exit 0
    fi
    exit 3
    ;;
  -)
    # post-install payload assertion (heredoc script on stdin, spec dir as $2)
    cat > /dev/null
    echo "INTERPRETER $0 :: payload-check $2" >> "${PIP_LOG:?}"
    main="$(sed -n 's/.*"mainJar"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      "$site/run_kotlin_kernel/config/jar_args.json" 2>/dev/null)"
    if [ -f "$2/kernel.json" ] && [ -d "$site/run_kotlin_kernel/jars" ] \
      && [ -n "$main" ] && [ -f "$site/run_kotlin_kernel/jars/$main" ]; then
      exit 0
    fi
    exit 1
    ;;
esac
echo "INTERPRETER $0 :: UNEXPECTED $*" >> "${PIP_LOG:?}"
exit 4
"""

# Stub `python3` on PATH for the no-conda fallback branch. Emulates a Debian
# (PEP 668) system interpreter: the EXTERNALLY-MANAGED probe succeeds, the
# sysconfig data path resolves to ${FALLBACK_PREFIX}, and `pip install`
# materialises the kernelspec + run_kotlin_kernel payload under that prefix.
# JSON-reading invocations (KQ_* env set, script on stdin) are forwarded to
# the real interpreter because this stub is a shell script.
_FALLBACK_PYTHON3_STUB = r"""
prefix="${FALLBACK_PREFIX:?}"
site="$prefix/lib/python3.12/site-packages"
spec="$prefix/share/jupyter/kernels/kotlin"
case "$1" in
  -c)
    case "$2" in
      *EXTERNALLY-MANAGED*)
        exit 0                          # marker present: installer must add --break-system-packages
        ;;
      *sysconfig.get_path*data*)
        echo "$prefix"                  # spec_dir derivation source
        exit 0
        ;;
      *)
        # idempotency probe: import run_kotlin_kernel
        if [ -f "$spec/kernel.json" ] && [ -f "$site/run_kotlin_kernel/__init__.py" ]; then
          exit 0
        fi
        exit 1
        ;;
    esac
    ;;
  -m)
    echo "INTERPRETER $0 :: $*" >> "${PIP_LOG:?}"
    if printf '%s\n' "$*" | grep -q -- "-m pip install --no-index --no-deps "; then
      wheel="$(printf '%s\n' "$*" | awk '{print $NF}')"
      [ -f "$wheel" ] || exit 2         # must install the verified local wheel
      printf '%s\n' "$*" | grep -q -- "--break-system-packages" || exit 5
      mkdir -p "$spec" "$site/run_kotlin_kernel/jars" "$site/run_kotlin_kernel/config"
      printf '%s\n' '{"argv":["python","-m","run_kotlin_kernel","{connection_file}"],"display_name":"Kotlin","language":"kotlin"}' > "$spec/kernel.json"
      printf '%s\n' '{"mainJar": "kotlin-jupyter-kernel-all.jar"}' > "$site/run_kotlin_kernel/config/jar_args.json"
      : > "$site/run_kotlin_kernel/jars/kotlin-jupyter-kernel-all.jar"
      : > "$site/run_kotlin_kernel/__init__.py"
      exit 0
    fi
    exit 3
    ;;
  -)
    if [ -n "${KQ_FILE:-}" ]; then
      exec "${REAL_PYTHON3:?}" -        # checksums.json reader needs a real interpreter
    fi
    # post-install payload assertion (heredoc on stdin, spec dir as $2)
    cat > /dev/null
    echo "INTERPRETER $0 :: payload-check $2" >> "${PIP_LOG:?}"
    main="$(sed -n 's/.*"mainJar"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      "$site/run_kotlin_kernel/config/jar_args.json" 2>/dev/null)"
    if [ -f "$2/kernel.json" ] && [ -d "$site/run_kotlin_kernel/jars" ] \
      && [ -n "$main" ] && [ -f "$site/run_kotlin_kernel/jars/$main" ]; then
      exit 0
    fi
    exit 1
    ;;
esac
echo "INTERPRETER $0 :: UNEXPECTED $*" >> "${PIP_LOG:?}"
exit 4
"""


class Sandbox:
    """tmp_path tree: bin/{curl,python3}, conda/bin/python, home/, checksums.json."""

    def __init__(self, tmp_path: Path, tag: str, *, with_checksums: bool = True) -> None:
        self.root = tmp_path / tag
        self.home = self.root / "home"
        self.conda = self.root / "conda"
        self.curl_log = self.root / "curl.log"
        self.pip_log = self.root / "pip.log"
        bin_dir = self.root / "bin"
        bin_dir.mkdir(parents=True, exist_ok=True)
        self.home.mkdir(parents=True, exist_ok=True)
        (self.conda / "bin").mkdir(parents=True, exist_ok=True)

        _write_exec(bin_dir / "curl", _CURL_STUB.replace("${WHEEL_CONTENT.stub}", '"$WHEEL_CONTENT"'))
        _write_exec(self.conda / "bin" / "python", _PYTHON_STUB)
        # Deterministic python3 for the installer's JSON fallback reader
        # (no jq on the sandbox PATH), immune to the macOS /usr/bin shim.
        link = bin_dir / "python3"
        if not link.exists():
            link.symlink_to(sys.executable)

        self.checksums = self.root / "checksums.json"
        if with_checksums:
            self.set_checksums(url=TEST_URL, sha=WHEEL_SHA)

    def set_checksums(self, *, url: str | None, sha: str | None) -> None:
        entry: dict = {"checksums": {}}
        if url is not None:
            entry["archive_url_template"] = url
        if sha is not None:
            entry["checksums"][TEST_VERSION] = {"amd64": sha, "arm64": sha}
        self.checksums.write_text(
            __import__("json").dumps({"tools": {"kotlin-jupyter": entry}}), encoding="utf-8"
        )

    def env(self, **extra: str) -> dict[str, str]:
        env = {
            "PATH": f"{self.root / 'bin'}:/usr/bin:/bin",
            "PWD": str(self.root),
            "HOME": str(self.home),
            "HOME_DIR": str(self.home),
            "CONDA_DIR": str(self.conda),
            "NB_USER": "jovyan",
            "NB_UID": "1001",
            "NB_GID": "1001",
            "INSTALL_KOTLIN": "false",
            "INSTALL_KOTLIN_KERNEL": "true",
            "KOTLIN_KERNEL_VERSION": TEST_VERSION,
            "KOTLIN_KERNEL_RETRY_DELAY": "0",
            "CURL_LOG": str(self.curl_log),
            "PIP_LOG": str(self.pip_log),
            "WHEEL_CONTENT": WHEEL_CONTENT.decode(),
        }
        env.update(extra)
        return env

    def run(self, installer: Path | None = None, **env_extra: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [BASH, str(installer or INSTALL_SH)],
            capture_output=True,
            text=True,
            env=self.env(**env_extra),
            timeout=60,
            cwd=str(self.root),
            check=False,
        )

    def curl_attempts(self) -> list[str]:
        if not self.curl_log.exists():
            return []
        return self.curl_log.read_text(encoding="utf-8").splitlines()

    def pip_invocations(self) -> list[str]:
        if not self.pip_log.exists():
            return []
        return self.pip_log.read_text(encoding="utf-8").splitlines()

    @property
    def spec_file(self) -> Path:
        return self.conda / "share" / "jupyter" / "kernels" / "kotlin" / "kernel.json"


def _pre_kernel_installer(tmp_path: Path) -> Path:
    proc = subprocess.run(
        ["git", "-C", str(REPO), "show", f"{PRE_KERNEL_REF}:features/kotlin/install.sh"],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0 or "ARTIFACTS or release URL" not in proc.stdout:
        pytest.skip(f"pre-kernel installer not retrievable at {PRE_KERNEL_REF} (shallow clone?)")
    path = tmp_path / "install_pre_kernel.sh"
    path.write_text(proc.stdout, encoding="utf-8")
    path.chmod(0o755)
    return path


# ---------------------------------------------------------------------------
# (a) fetch failure: loud, bounded retry x3
# ---------------------------------------------------------------------------
def test_fetch_failure_exits_nonzero_after_three_attempts(tmp_path):
    sb = Sandbox(tmp_path, "fetch")
    proc = sb.run(CURL_FAIL_UNTIL="999")  # every attempt fails

    assert proc.returncode == 1, f"rc={proc.returncode} stderr={proc.stderr!r}"
    assert len(sb.curl_attempts()) == 3, f"expected exactly 3 attempts: {sb.curl_attempts()}"
    err = proc.stderr
    assert "FAILED to download" in err
    assert WHEEL_NAME in err                      # names the wheel
    assert TEST_VERSION in err                    # names the pinned version
    assert WHEEL_SHA in err                       # names the expected digest
    assert "lang-kotlin" in err                   # names the consumer
    assert "after 3 attempts" in err              # explicit about the bound
    assert "attempt 1/3" in err and "attempt 2/3" in err
    assert not sb.pip_invocations(), "pip must not run after a failed fetch"
    assert "kotlin: done" not in proc.stdout


# ---------------------------------------------------------------------------
# (b) checksum mismatch: single attempt, never retried, pip never invoked
# ---------------------------------------------------------------------------
def test_checksum_mismatch_fails_after_single_attempt_without_pip(tmp_path):
    sb = Sandbox(tmp_path, "mismatch")
    # curl succeeds immediately but serves content that does not match the pin.
    proc = sb.run(WHEEL_CONTENT="SUBSTITUTED-CORRUPT-CONTENT")

    assert proc.returncode == 1
    assert len(sb.curl_attempts()) == 1, (
        "a digest mismatch must NOT be retried: a retry that could land a "
        f"matching artefact turns content failure into a pass: {sb.curl_attempts()}"
    )
    err = proc.stderr
    assert "FAILED checksum verification" in err
    assert WHEEL_SHA in err                       # expected digest
    assert re.search(r"got [0-9a-f]{64}", err)    # actual digest
    assert WHEEL_NAME in err and TEST_VERSION in err
    assert "not retrying" in err
    assert "lang-kotlin" in err
    assert not sb.pip_invocations(), "pip must never be invoked for an unverified wheel"
    assert not sb.spec_file.exists()


# ---------------------------------------------------------------------------
# (c) happy path: flags, interpreter, payload
# ---------------------------------------------------------------------------
def test_happy_path_uses_no_index_no_deps_and_exact_interpreter(tmp_path):
    sb = Sandbox(tmp_path, "happy")
    proc = sb.run()

    assert proc.returncode == 0, proc.stderr
    assert len(sb.curl_attempts()) == 1
    assert sb.curl_attempts()[0].endswith(TEST_URL)
    assert f"kotlin: wheel verified: sha256 {WHEEL_SHA}" in proc.stdout

    pip_log = sb.pip_invocations()
    installs = [ln for ln in pip_log if "pip install" in ln]
    assert len(installs) == 1, pip_log
    assert "--no-index --no-deps" in installs[0]
    assert WHEEL_NAME in installs[0]
    # The exact interpreter: the notebook stack's own miniforge python, named
    # as $0 by the stub itself (not merely present in the log line).
    assert installs[0].startswith(f"INTERPRETER {sb.conda / 'bin' / 'python'} ::")

    assert sb.spec_file.is_file()
    assert any("payload-check" in ln for ln in pip_log), "payload assertion must have run"
    assert "kotlin: kernel installed" in proc.stdout
    assert (sb.home / ".jupyter_kotlin" / "cache").is_dir()
    assert (sb.home / ".m2" / "repository").is_dir()
    assert "kotlin: done" in proc.stdout


def test_no_interpreter_at_all_fails_closed(tmp_path):
    """Replacement for test_missing_interpreter_refuses_to_fall_back: the
    fail-closed guard is preserved, narrowed to the case where NEITHER the
    conda python NOR a python3 on PATH exists. Non-zero exit, before any
    download, naming both attempted interpreters — the silent-skip class of
    failure (a kernel gate that passes while shipping no kernel) remains
    impossible."""
    sb = Sandbox(tmp_path, "nopython")
    shutil.rmtree(sb.conda)
    (sb.root / "bin" / "python3").unlink()
    # Strip /usr/bin and /bin so the host's python3 is not on the PATH the
    # installer resolves; the sandbox bin carries only the curl stub.
    proc = sb.run(PATH=str(sb.root / "bin"))

    assert proc.returncode == 1
    err = proc.stderr
    assert str(sb.conda / "bin" / "python") in err, "must name the conda path it tried"
    assert "python3" in err, "must name the PATH fallback it tried"
    assert "refusing to proceed without one" in err
    assert not sb.curl_attempts(), "must refuse before any download"


def test_conda_absent_installs_with_python3_from_path(tmp_path):
    """The python3 fallback branch (lang-kotlin's closure has no
    python-conda). The stub python3 emulates a Debian PEP 668 interpreter:
    the EXTERNALLY-MANAGED probe succeeds, so the install must carry
    --break-system-packages, and the kernelspec must be verified under the
    interpreter's sysconfig data prefix, not CONDA_DIR."""
    sb = Sandbox(tmp_path, "fallback")
    shutil.rmtree(sb.conda)  # no miniforge in this closure
    prefix = sb.root / "usr-local"
    prefix.mkdir(parents=True)
    stub = sb.root / "bin" / "python3"
    stub.unlink()  # replace the real-python symlink with the prefix-aware stub
    _write_exec(stub, _FALLBACK_PYTHON3_STUB)

    proc = sb.run(FALLBACK_PREFIX=str(prefix), REAL_PYTHON3=sys.executable)

    assert proc.returncode == 0, proc.stderr
    assert "python3 from PATH" in proc.stdout, "fallback must be announced, not silent"
    assert len(sb.curl_attempts()) == 1

    pip_log = sb.pip_invocations()
    installs = [ln for ln in pip_log if "pip install" in ln]
    assert len(installs) == 1, pip_log
    # The fallback interpreter performed the registration ($0 names it).
    assert installs[0].startswith(f"INTERPRETER {stub} ::"), installs[0]
    assert "--no-index --no-deps --break-system-packages" in installs[0], (
        "a PEP 668 interpreter must receive --break-system-packages; the "
        f"pip line was: {installs[0]}"
    )
    spec = prefix / "share" / "jupyter" / "kernels" / "kotlin" / "kernel.json"
    assert spec.is_file(), "kernelspec must be asserted where this interpreter writes it"
    assert not sb.conda.exists()
    assert any("payload-check" in ln for ln in pip_log)
    assert "kotlin: kernel installed" in proc.stdout
    assert "kotlin: done" in proc.stdout


# ---------------------------------------------------------------------------
# no-digest / no-URL guards: an unverified download never starts
# ---------------------------------------------------------------------------
def test_no_digest_means_no_fetch(tmp_path):
    sb = Sandbox(tmp_path, "nodigest")
    sb.set_checksums(url=TEST_URL, sha=None)
    proc = sb.run()

    assert proc.returncode == 1
    assert "no pinned sha256" in proc.stderr
    assert "Refusing an unverified download" in proc.stderr
    assert "lang-kotlin" in proc.stderr
    assert not sb.curl_attempts()


def test_no_url_means_no_fetch(tmp_path):
    sb = Sandbox(tmp_path, "nourl")
    sb.set_checksums(url=None, sha=WHEEL_SHA)
    proc = sb.run()

    assert proc.returncode == 1
    assert "no wheel URL" in proc.stderr
    assert WHEEL_SHA in proc.stderr  # still names the expected digest
    assert not sb.curl_attempts()


def test_wheel_url_option_override(tmp_path):
    sb = Sandbox(tmp_path, "override")
    custom = f"https://mirror.invalid/{WHEEL_NAME}"
    proc = sb.run(KOTLIN_KERNEL_WHEEL_URL=custom)

    assert proc.returncode == 0, proc.stderr
    assert sb.curl_attempts() == [f"1 {custom}"], sb.curl_attempts()


# ---------------------------------------------------------------------------
# (d) false gate: byte-identical to the pre-kernel installer
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("gate", ["false", "False", "FALSE"])
def test_false_gate_stdout_identical_to_pre_kernel_installer(tmp_path, gate):
    old = Sandbox(tmp_path, "old")
    new = Sandbox(tmp_path, "new")
    proc_old = old.run(installer=_pre_kernel_installer(tmp_path), INSTALL_KOTLIN_KERNEL=gate)
    proc_new = new.run(INSTALL_KOTLIN_KERNEL=gate)

    assert proc_old.returncode == 0, proc_old.stderr
    assert proc_new.returncode == 0, proc_new.stderr
    assert proc_new.stdout == proc_old.stdout, (
        "false gate must be a no-op versus the pre-kernel installer"
    )
    assert f"kernel={gate.lower()}" in proc_new.stdout
    assert not new.curl_attempts(), "false gate must never reach the network"
    assert not new.pip_invocations()
    assert not new.spec_file.exists()


# ---------------------------------------------------------------------------
# (e) truthy casings all enter the kernel gate
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("gate", ["true", "True", "TRUE"])
def test_kernel_gate_enters_for_all_truthy_spellings(tmp_path, gate):
    sb = Sandbox(tmp_path, f"case-{gate}")
    proc = sb.run(INSTALL_KOTLIN_KERNEL=gate)

    assert proc.returncode == 0, proc.stderr
    assert f"kernel={gate.lower()}" in proc.stdout  # normalised banner
    assert len(sb.curl_attempts()) == 1, f"gate {gate!r} skipped the kernel install"
    assert sb.spec_file.is_file()


# ---------------------------------------------------------------------------
# (f) idempotency: second invocation skips the fetch
# ---------------------------------------------------------------------------
def test_second_invocation_skips_fetch(tmp_path):
    sb = Sandbox(tmp_path, "idem")
    first = sb.run()
    assert first.returncode == 0, first.stderr

    second = sb.run()
    assert second.returncode == 0, second.stderr
    assert "kernel already present" in second.stdout
    assert len(sb.curl_attempts()) == 1, "second run must not re-fetch the wheel"
    assert len(sb.pip_invocations()) == 2, "only the first run may invoke pip"


# ---------------------------------------------------------------------------
# structural guards on the installer source
# ---------------------------------------------------------------------------
def test_installer_does_not_use_rejected_registration_paths():
    """fix-kernelspec-location and add-kernel are documented non-options:

    the former copies specs into the *user* data dir (-> /root/... under a
    root build, invisible to ${NB_USER}); the latter registers 'kotlin_<name>',
    never the plain 'kotlin' spec the profile advertises. The wheel's own
    DATA_FILES placement is what registers the spec, so neither may be *called*
    (prose mentions in comments are fine).
    """
    for token in ("fix-kernelspec-location", "add-kernel"):
        for i, line in enumerate(INSTALL_SH.read_text(encoding="utf-8").splitlines(), 1):
            if token in line:
                assert line.lstrip().startswith("#"), (
                    f"{token} appears in a non-comment line {i}: {line!r}"
                )


def test_installer_never_hand_writes_kernel_json():
    """The kernelspec must come from the wheel's own DATA_FILES payload.

    No line may write (redirect/tee/heredoc-emit) a path ending in
    ``kernels/kotlin/kernel.json``; the only kernel.json mentions allowed are
    existence checks (``[ -f ... ]``) and comments.
    """
    writing = re.compile(r"(?:^|[^<])(?:-{1,2}tee|>)\s*[\"']?[^\s\"']*kernels/kotlin/kernel\.json")
    for i, line in enumerate(INSTALL_SH.read_text(encoding="utf-8").splitlines(), 1):
        if "kernels/kotlin/kernel.json" in line and not line.lstrip().startswith("#"):
            assert writing.search(line) is None, f"line {i} writes the kernelspec: {line!r}"
