"""Regression guard: java-jdk installs the PINNED Temurin pair from the
digest-verified offline toolcache mirror — never a live SDKMAN fetch on the
pinned path.

Sibling of tests/test_java_gradle_is_mirrored.py, same discipline: predicates
evaluate the REAL shipped installer text and the REAL
scripts/stage-toolcache.sh ``--mode list`` output, never duplicated strings,
so the tests cannot rot. Compact on purpose — CI runs the authoritative full
suite; this module pins: (a) routing, (b) per-arch URL parity, (c) digests +
pin, (d) 13-tool staging breadth, (e) fail-closed (no releases/latest, no
sdk install java on the pinned branch).
"""

import json
import os
import re
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
INSTALLER = REPO / "features" / "java-jdk" / "install.sh"
STAGE_SCRIPT = REPO / "scripts" / "stage-toolcache.sh"

ARCHES = ("amd64", "arm64")
PIN = "25.0.4.1+1"
# Canonical adoptium per-major release URL the mirror must stage per arch
# ('+' %-encoded in the tag, '_' in the asset name — the installer's own
# DOWNLOAD_URL construction).
EXPECTED_URL = {
    "amd64": ("https://github.com/adoptium/temurin25-binaries/releases/"
              "download/jdk-25.0.4.1%2B1/OpenJDK25U-jdk_x64_linux_hotspot_"
              "25.0.4.1_1.tar.gz"),
    "arm64": ("https://github.com/adoptium/temurin25-binaries/releases/"
              "download/jdk-25.0.4.1%2B1/OpenJDK25U-jdk_aarch64_linux_hotspot_"
              "25.0.4.1_1.tar.gz"),
}


def _bash():
    for cand in ("/opt/homebrew/bin/bash", "/usr/local/bin/bash", "/bin/bash"):
        if Path(cand).is_file():
            r = subprocess.run([cand, "-c", 'echo "${BASH_VERSINFO[0]}"'],
                               capture_output=True, text=True, check=False)
            if r.returncode == 0 and int(r.stdout.strip()) >= 4:
                return cand
    pytest.skip("bash >= 4 not available")


def _text(path):
    return Path(path).read_text(encoding="utf-8")


def _versions():
    return json.loads(_text(REPO / "versions.json"))["tools"]


def _checksums():
    return json.loads(_text(REPO / "checksums.json"))["tools"]


def _list_output(arch):
    """`stage-toolcache.sh --mode list --arch <arch>` stdout — same
    VERSIONS_FILE/CHECKSUMS_FILE env and cwd as the gradle sibling so the SoT
    files resolve identically."""
    env = dict(os.environ,
               VERSIONS_FILE=str(REPO / "versions.json"),
               CHECKSUMS_FILE=str(REPO / "checksums.json"))
    r = subprocess.run(
        [_bash(), str(STAGE_SCRIPT), "--mode", "list", "--arch", arch],
        capture_output=True, text=True, env=env, cwd=str(REPO), check=False)
    assert r.returncode == 0, r.stderr
    return r.stdout


def _jdk_row(out, arch):
    rows = [ln for ln in out.splitlines()
            if re.search(r"(^|\t)jdk(\t|$)", ln) and f"\t{arch}\t" in ln]
    assert len(rows) == 1, rows
    return rows[0]


# ---------------------------------------------------------------------------
# (a) routing
# ---------------------------------------------------------------------------

def test_pinned_routing_present():
    text = _text(INSTALLER)
    # The pinned branch fetches through the shared mirror helper with the jdk
    # tool arg (download_direct keys the toolcache by tool + URL basename).
    assert re.search(
        r'download_direct\s+"\$DOWNLOAD_URL"\s+"jdk"\s+"\$\{?VERSION\}?"',
        text), "pinned branch must call download_direct with the jdk tool arg"
    # Fail-closed by default: leaving the mirror path needs an explicit opt-in.
    assert re.search(
        r"^JAVA_JDK_ALLOW_SDKMAN_FALLBACK=\$\{JAVA_JDK_ALLOW_SDKMAN_FALLBACK:"
        r"-false\}", text, re.MULTILINE), \
        "JAVA_JDK_ALLOW_SDKMAN_FALLBACK must default to false"
    assert "jdk_request_is_pinned" in text
    # Both fail-closed tokens the build greps for.
    assert "FH_VERSION_UNRESOLVED" in text
    assert "FH_JAVA_JDK_INSTALL_FAILED" in text
    # The URL construction the parity in (b) depends on: adoptium per-major
    # release repo, '+' %-encoded in the tag and '_' in the asset name.
    assert re.search(
        r'DOWNLOAD_URL="https://github\.com/adoptium/temurin25-binaries/'
        r'releases/download/jdk-\$\{VERSION//\+/%2B\}/OpenJDK\$\{VERSION%%\.\*'
        r'\}U-jdk_\$\{RELEASE_ARCH\}_linux_hotspot_\$\{VERSION//\+/_\}\.tar\.gz"',
        text), "installer DOWNLOAD_URL drifted from the adoptium release URL"
    # Arch mapping in lock-step with the stager's per-arch rows.
    assert re.search(r'amd64\)\s+RELEASE_ARCH="x64"', text)
    assert re.search(r'arm64\)\s+RELEASE_ARCH="aarch64"', text)


# ---------------------------------------------------------------------------
# (b) url parity (stager side; the installer side is pinned in (a))
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("arch", ARCHES)
def test_url_parity_both_arches(arch):
    row = _jdk_row(_list_output(arch), arch)
    urls = re.findall(r"https?://[^\s\t]+", row)
    assert urls == [EXPECTED_URL[arch]], \
        f"stager jdk row URL for {arch} diverged from the canonical adoptium " \
        "release URL — the mirror key would silently never hit"


# ---------------------------------------------------------------------------
# (c) digests
# ---------------------------------------------------------------------------

def test_digests_and_pin():
    blk = _checksums()["jdk"]
    assert blk["pinned_version"] == _versions()["jdk"] == PIN
    digests = blk["checksums"][PIN]
    for arch in ARCHES:
        assert re.fullmatch(r"[0-9a-f]{64}", digests[arch]), digests[arch]
    # Temurin publishes SEPARATE per-arch assets (unlike gradle's single
    # -bin.zip): any future equality means the staging assumption broke.
    assert digests["amd64"] != digests["arm64"]


# ---------------------------------------------------------------------------
# (d) staging breadth
# ---------------------------------------------------------------------------

def test_staging_breadth_thirteen():
    out = _list_output("amd64,arm64")
    rows = [ln for ln in out.splitlines()
            if len(ln.split("\t")) >= 2 and ln.split("\t")[1] in ARCHES]
    tools = {ln.split("\t")[0] for ln in rows}
    assert len(tools) == 13, sorted(tools)
    for arch in ARCHES:
        assert sum(1 for ln in rows if ln.split("\t")[1] == arch) == 13, \
            f"expected 13 tools staged for {arch}"
    row = _jdk_row(out, "amd64")
    assert re.search(r"\b[0-9a-f]{64}\b", row), row
    assert re.search(r"https?://[^\s\t]+", row), row


# ---------------------------------------------------------------------------
# (e) fail-closed: no live latest tag, no SDKMAN transport on the pinned path
# ---------------------------------------------------------------------------

def test_no_live_fallback_on_pinned_path():
    text = _text(INSTALLER)
    assert "releases/latest" not in text, \
        "the pinned path must not reference a moving 'latest' release tag"
    # The pinned branch is the block from the routing guard to the first
    # column-0 `else` (the legacy branch). It must route to the mirror and
    # carry no `sdk install java` invocation of its own (comment prose is
    # stripped — the gradle test's curl-invocation lesson).
    m = re.search(r"^if jdk_request_is_pinned[^\n]*\n(.*?)^else\n",
                  text, re.MULTILINE | re.DOTALL)
    assert m, "pinned-branch routing guard (jdk_request_is_pinned) not found"
    code = "\n".join(ln for ln in m.group(1).splitlines()
                     if not ln.lstrip().startswith("#"))
    assert "download_direct" in code, \
        "the pinned branch must route to download_direct"
    assert "sdk install java" not in code, \
        "the pinned branch must not run a live SDKMAN install"
