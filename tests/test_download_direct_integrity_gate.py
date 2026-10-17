"""Behavioural tests for the download_direct integrity gate (commit 6d7bd4e).

`download_direct` (features/_lib/download-release/install.sh) now verifies
every archive against the publisher digest in checksums.json via
fh_resolve_checksum BEFORE any toolcache write, and fails closed when the
digest is missing. The container path that normally executes this was out of
scope for the commit, so these tests prove the gate works without docker:

  * the helper library is extracted verbatim from the heredoc in install.sh
    (the `cat > "$HELPER_LIB" << 'HELPER_EOF'` ... `HELPER_EOF` block) and
    sourced in a bash subprocess — the tests run the real shipped code, so
    they track any later edit of that file;
  * `curl` is stubbed on PATH (writes a known payload to the `-o` target);
    no network is ever touched;
  * checksums.json is staged under a tmp_path and pointed at via
    FH_REPO_ROOT — never the shared /tmp candidates;
  * hashing stays portable: the system sha256sum is used when present, a
    python hashlib shim is installed on PATH when not (macOS runners).

Properties pinned here:

  1. missing digest  -> rc=1, the documented refusal on stderr, nothing
     installed, nothing written to TOOLCACHE_DIR (fail closed);
  2. poisoned bytes  -> rc=1 with the mismatch message and TOOLCACHE_DIR
     still completely empty: the bad archive is rejected BEFORE the cache
     write, so it can never be replayed by later builds;
  3. `_dr_version_key` strips exactly one leading "v" (checksum-lookup
     normalisation only), and download_direct verifies successfully with
     VERSION given as both "v4.0.4" and "4.0.4" against a real tar.gz whose
     digest is recorded under the v-less key "4.0.4";
  4. FH_ALLOW_MISSING_CHECKSUMS=true is the only escape hatch and it works
     (the fail-closed default is a deliberate choice, not an accident);
  5. a mismatch evicts a pre-seeded poisoned cache entry and installs
     nothing;
  6. the six committed pins (kubectl 1.34.1, helm 4.0.4, kustomize 5.7.1,
     k9s 0.50.18, tilt 0.36.0, tinytex 2026.09) each resolve in the
     committed checksums.json to a well-formed 64-hex digest for both CI
     architectures — offline, so a future pin landing without a digest
     fails the gate instead of every container build.

No container, no network, no shared /tmp residue: every tool name is
prefixed `solen-ddig-` and /tmp/<tool>.download / /tmp/<tool>-extract are
removed in teardown even though the gate deletes them itself.
"""

import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
INSTALL_SH = REPO / "features" / "_lib" / "download-release" / "install.sh"
FH_HELPERS = REPO / "features" / "_lib" / "fh_helpers.sh"
CHECKSUMS_JSON = REPO / "checksums.json"

HEREDOC_START = """cat > "$HELPER_LIB" << 'HELPER_EOF'"""
HEREDOC_END = "HELPER_EOF"

# Files fh_resolve_checksum probes BEFORE ${FH_REPO_ROOT}/checksums.json.
# They must not exist, or resolution would silently come from shared state.
SHARED_CHECKSUM_CANDIDATES = (
    "/tmp/checksums.json",
    "/tmp/artefacts/checksums.json",
    "/opt/solen/artefacts/checksums.json",
)

# The download_direct cache key is $TOOLCACHE_DIR/$tool/$(basename "$url");
# the harness fixes the URL to mirror.invalid/<tool>.tar.gz, so:
CACHE_ARCNAME = "{tool}.tar.gz"

# Real pins shipped at 6d7bd4e (tool, v-less checksums.json key).
COMMITTED_PINS = [
    ("kubectl", "1.34.1"),
    ("helm", "4.0.4"),
    ("kustomize", "5.7.1"),
    ("k9s", "0.50.18"),
    ("tilt", "0.36.0"),
    ("tinytex", "2026.09"),
]

_HEX64 = re.compile(r"\A[0-9a-f]{64}\Z")

# --- bash >= 4 resolution (macOS /bin/bash is 3.2); same approach as
# tests/test_kotlin_install_failure_is_loud.py ---------------------------------
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
        "no bash >= 4 found; the download-release helper library requires bash 4+",
        allow_module_level=True,
    )


def _helper_lib_body():
    """Extract the heredoc body install.sh writes to $HELPER_LIB."""
    lines = INSTALL_SH.read_text().splitlines()
    starts = [i for i, line in enumerate(lines) if line == HEREDOC_START]
    ends = [i for i, line in enumerate(lines) if line == HEREDOC_END]
    assert len(starts) == 1 and len(ends) == 1, (
        "expected exactly one HELPER_EOF heredoc in "
        f"{INSTALL_SH}, got starts={starts} ends={ends}"
    )
    assert starts[0] < ends[0]
    return "\n".join(lines[starts[0] + 1 : ends[0]]) + "\n"


def _tar_gz(member_name, payload):
    """A real one-file tar.gz laid out like a release archive (binary at root)."""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        info = tarfile.TarInfo(member_name)
        info.size = len(payload)
        info.mode = 0o755
        tf.addfile(info, io.BytesIO(payload))
    return buf.getvalue()


def _sha256(data):
    return hashlib.sha256(data).hexdigest()


def _checksums_doc(entries):
    """Build a canonical checksums.json doc: tools.<tool>.checksums.<ver>.<arch>.

    Both CI architectures (amd64/arm64) carry the same digest so resolution
    succeeds on linux x64, linux arm64 and macOS arm64 alike, through either
    the jq or the python path of fh_resolve_checksum.
    """
    tools = {}
    for tool, version, digest in entries:
        tool_obj = tools.setdefault(tool, {"checksums": {}})
        tool_obj["checksums"][version] = {"amd64": digest, "arm64": digest}
    return {"meta": {"test-harness": True}, "tools": tools}


class _Harness:
    """Stages the bash sandbox and runs download_direct in it.

    Each run gets its own work dir (multiple runs per test are allowed);
    /tmp/<tool>.download and /tmp/<tool>-extract are registered for
    teardown cleanup.
    """

    def __init__(self, tmp_path, request):
        self._tmp_path = tmp_path
        self._helper_body = _helper_lib_body()
        self._runs = 0
        # One shared stub curl + sha256sum shim dir per harness: the curl
        # stub reads $DR_STUB_FILE, which each run repoints at its payload.
        self._bin = tmp_path / "bin"
        self._bin.mkdir()
        curl = self._bin / "curl"
        curl.write_text(
            "#!/bin/bash\n"
            '# Stub: satisfy `curl "${flags[@]}" -o <target> <url>` by '
            "copying $DR_STUB_FILE to the -o target.\n"
            'out=""\n'
            'args=("$@")\n'
            'for ((i=1; i<=${#args[@]}; i++)); do\n'
            '  if [ "${args[$((i-1))]}" = "-o" ]; then out="${args[$i]}"; fi\n'
            "done\n"
            '[ -n "$out" ] || exit 2\n'
            'cat "$DR_STUB_FILE" > "$out"\n'
            "exit 0\n"
        )
        curl.chmod(0o755)
        if shutil.which("sha256sum") is None:
            # GNU-less platform: provide sha256sum in the exact
            # `<hex>  <path>` format the gate parses with awk.
            shim = self._bin / "sha256sum"
            shim.write_text(
                "#!/bin/bash\n"
                f"exec {sys.executable} -c "
                "'import hashlib,sys\\n"
                'for p in sys.argv[1:]:\\n'
                '    if p.startswith("-"):\\n'
                "        continue\\n"
                '    print(hashlib.sha256(open(p, "rb").read()).hexdigest() + "  " + p)\\n'
                "' \"$@\"\n"
            )
            shim.chmod(0o755)
        self._request = request

    def run(self, tool, version, payload, checksums_doc, env_extra=None, seed_cache=None):
        """Invoke download_direct URL TOOL VERSION INSTALL_DIR EXTRACT.

        Returns (completed_process, paths-dict). `payload` is the bytes the
        stub curl serves; `seed_cache` (bytes) pre-populates the toolcache
        entry download_direct would key as $TOOLCACHE_DIR/<tool>/<basename>.
        """
        self._runs += 1
        work = self._tmp_path / f"run-{self._runs}"
        (work / "install").mkdir(parents=True)
        (work / "toolcache").mkdir()
        repo = work / "repo"
        repo.mkdir()
        (repo / "checksums.json").write_text(json.dumps(checksums_doc))

        lib = work / "helpers.sh"
        lib.write_text(self._helper_body)
        payload_file = work / "payload.bin"
        payload_file.write_bytes(payload)

        driver = work / "driver.sh"
        driver.write_text(
            "#!/bin/bash\n"
            "set -uo pipefail\n"
            f"source '{lib}'\n"
            f"source '{FH_HELPERS}'\n"
            # fh_helpers.sh turns errexit on; the unit under test signals
            # failures via `return 1`, so capture rc instead of aborting.
            "set +e\n"
            'download_direct "$DR_URL" "$DR_TOOL" "$DR_VERSION" '
            '"$DR_INSTALL_DIR" "$DR_EXTRACT"\n'
            "exit $?\n"
        )

        cache_archive = work / "toolcache" / tool / CACHE_ARCNAME.format(tool=tool)
        if seed_cache is not None:
            cache_archive.parent.mkdir(parents=True)
            cache_archive.write_bytes(seed_cache)

        env = os.environ.copy()
        env["PATH"] = f"{self._bin}{os.pathsep}{env['PATH']}"
        env["DR_STUB_FILE"] = str(payload_file)
        env["DR_URL"] = f"https://mirror.invalid/{CACHE_ARCNAME.format(tool=tool)}"
        env["DR_TOOL"] = tool
        env["DR_VERSION"] = version
        env["DR_INSTALL_DIR"] = str(work / "install")
        env["DR_EXTRACT"] = "true"
        env["TOOLCACHE_DIR"] = str(work / "toolcache")
        env["FH_REPO_ROOT"] = str(repo)
        env.pop("FH_ALLOW_MISSING_CHECKSUMS", None)
        if env_extra:
            env.update(env_extra)

        for residue in (f"/tmp/{tool}.download", f"/tmp/{tool}-extract"):
            self._request.addfinalizer(lambda r=residue: Path(r).unlink(missing_ok=True))

        proc = subprocess.run(
            [BASH, str(driver)],
            env=env,
            capture_output=True,
            text=True,
            timeout=120,
            check=False,  # the rc of download_direct IS the assertion
        )
        paths = {
            "work": work,
            "install_dir": work / "install",
            "toolcache": work / "toolcache",
            "cache_archive": cache_archive,
        }
        return proc, paths


@pytest.fixture()
def harness(tmp_path, request):
    return _Harness(tmp_path, request)


@pytest.fixture(autouse=True)
def _no_shared_checksum_state():
    for candidate in SHARED_CHECKSUM_CANDIDATES:
        if Path(candidate).exists():
            pytest.fail(
                f"hermeticity precondition violated: {candidate} exists; "
                "fh_resolve_checksum probes it before FH_REPO_ROOT, so the "
                "stubbed digests would be ignored"
            )


def _regular_files(path):
    return sorted(p.name for p in path.rglob("*") if p.is_file())


class TestVersionKeyNormalisation:
    """_dr_version_key strips exactly one leading 'v' (lookup key only)."""

    @pytest.mark.parametrize(
        ("given", "expected"),
        [
            ("v4.0.4", "4.0.4"),
            ("4.0.4", "4.0.4"),
            ("vv1.2.3", "v1.2.3"),  # ONE leading v only
            ("", ""),
        ],
    )
    def test_dr_version_key(self, tmp_path, given, expected):
        lib = tmp_path / "helpers.sh"
        lib.write_text(_helper_lib_body())
        proc = subprocess.run(
            [BASH, "-c", f"source '{lib}' && _dr_version_key '{given}'"],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        assert proc.returncode == 0, proc.stderr
        assert proc.stdout == expected


class TestMissingDigestFailsClosed:
    """Case 1: no digest resolvable -> refuse to install or cache."""

    def test_refuses_install_and_cache_write(self, harness):
        tool = "solen-ddig-missing"
        proc, paths = harness.run(
            tool=tool,
            version="4.0.4",
            payload=_tar_gz(tool, b"whatever bytes"),
            checksums_doc=_checksums_doc([]),
        )
        assert proc.returncode == 1
        assert (
            f"❌ Checksum not found for {tool}@4.0.4 via fh_resolve_checksum — "
            "refusing to install or cache an unverified archive "
            "(set FH_ALLOW_MISSING_CHECKSUMS=true to override)"
        ) in proc.stderr.splitlines()
        assert _regular_files(paths["toolcache"]) == []
        assert _regular_files(paths["install_dir"]) == []
        # The gate cleans its own download scratch file.
        assert not Path(f"/tmp/{tool}.download").exists()


class TestCorruptedArchiveRejectedBeforeCacheWrite:
    """Case 2: bytes not matching the recorded digest never reach the cache."""

    def test_poisoned_payload_is_not_persisted(self, harness):
        tool = "solen-ddig-corrupt"
        # One bytes object per archive: tar/gzip streams are not byte-stable
        # (the gzip header carries an mtime), so the digest asserted here must
        # be taken from the exact bytes the stub curl serves.
        poisoned = _tar_gz(tool, b"poisoned bytes")
        good_digest = _sha256(_tar_gz(tool, b"publisher-approved bytes"))
        proc, paths = harness.run(
            tool=tool,
            version="4.0.4",
            payload=poisoned,  # served != recorded
            checksums_doc=_checksums_doc([(tool, "4.0.4", good_digest)]),
        )
        assert proc.returncode == 1
        assert (
            f"❌ Checksum mismatch for {tool}@4.0.4: "
            f"expected {good_digest}, got {_sha256(poisoned)}"
        ) in proc.stderr.splitlines()
        # The decisive property: the toolcache tree is EMPTY (not even a
        # lock artefact) — the gate returned before the cache-write section.
        assert _regular_files(paths["toolcache"]) == []
        assert _regular_files(paths["install_dir"]) == []


class TestVPrefixEndToEnd:
    """Case 3: 'v4.0.4' and '4.0.4' both verify against key '4.0.4'."""

    @pytest.mark.parametrize("given_version", ["v4.0.4", "4.0.4"])
    def test_verifies_and_installs(self, harness, given_version):
        tool = "solen-ddig-vprefix"
        payload = _tar_gz(tool, b"real release content")
        digest = _sha256(payload)
        proc, paths = harness.run(
            tool=tool,
            version=given_version,
            payload=payload,
            checksums_doc=_checksums_doc([(tool, "4.0.4", digest)]),
        )
        assert proc.returncode == 0, proc.stderr
        assert f"   Verifying checksum for {tool}@4.0.4..." in proc.stdout.splitlines()
        assert "   ✅ Checksum verified" in proc.stdout.splitlines()
        installed = paths["install_dir"] / tool
        assert installed.is_file() and os.access(installed, os.X_OK)
        assert paths["cache_archive"].read_bytes() == payload  # genuine bytes cached


class TestEscapeHatch:
    """Case 4: FH_ALLOW_MISSING_CHECKSUMS=true proceeds without a digest."""

    def test_proceeds_when_explicitly_allowed(self, harness):
        tool = "solen-ddig-escape"
        payload = _tar_gz(tool, b"content without a recorded digest")
        proc, paths = harness.run(
            tool=tool,
            version="4.0.4",
            payload=payload,
            checksums_doc=_checksums_doc([]),
            env_extra={"FH_ALLOW_MISSING_CHECKSUMS": "true"},
        )
        assert proc.returncode == 0, proc.stderr
        assert (
            f"   ⚠️  No checksum available for {tool}@4.0.4; "
            "skipping verification due to FH_ALLOW_MISSING_CHECKSUMS=true"
        ) in proc.stdout.splitlines()
        assert (paths["install_dir"] / tool).is_file()


class TestMismatchEvictsPoisonedCacheEntry:
    """Case 5: a bad pre-seeded cache archive is removed and nothing installed."""

    def test_bad_cache_entry_is_evicted(self, harness):
        tool = "solen-ddig-evict"
        payload = _tar_gz(tool, b"publisher-approved bytes")
        digest = _sha256(payload)
        poisoned = _tar_gz(tool, b"attacker bytes already in the cache")
        proc, paths = harness.run(
            tool=tool,
            version="4.0.4",
            payload=payload,
            checksums_doc=_checksums_doc([(tool, "4.0.4", digest)]),
            seed_cache=poisoned,
        )
        assert proc.returncode == 1
        assert (
            f"❌ Checksum mismatch for {tool}@4.0.4: "
            f"expected {digest}, got {_sha256(poisoned)}"
        ) in proc.stderr.splitlines()
        assert (
            f"   Removed bad cache: {paths['cache_archive']}" in proc.stdout.splitlines()
        )
        assert not paths["cache_archive"].exists()
        # Only the flock artefact (.lockfile) may remain — no archive bytes.
        assert _regular_files(paths["toolcache"]) == [".lockfile"]
        assert _regular_files(paths["install_dir"]) == []


class TestCommittedPinsResolvable:
    """Case 6: offline guard — every shipped pin has a well-formed digest.

    Mirrors exactly what fh_resolve_checksum looks up
    (.tools[<tool>].checksums[<v-less version>].<amd64|arm64>), so a future
    version bump landing without a recorded digest fails here instead of
    breaking every container build on the fail-closed gate.
    """

    @pytest.mark.parametrize(("tool", "version"), COMMITTED_PINS)
    def test_pin_has_64_hex_digest_for_both_ci_arches(self, tool, version):
        doc = json.loads(CHECKSUMS_JSON.read_text())
        entry = doc.get("tools", {}).get(tool, {}).get("checksums", {}).get(version)
        assert isinstance(entry, dict), (
            f"{tool}@{version} missing from committed checksums.json"
        )
        for arch in ("amd64", "arm64"):
            digest = entry.get(arch)
            assert digest is not None, f"{tool}@{version} has no {arch} digest"
            assert _HEX64.match(digest), f"{tool}@{version}.{arch} not 64-hex: {digest!r}"
