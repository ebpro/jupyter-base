"""Regression guard: java-gradle installs Gradle from the PINNED, digest-
verified toolcache mirror path — never via ``sdk install gradle`` again.

Sibling of tests/test_zsh_starship_is_mirrored.py, same discipline: the
predicates evaluate the REAL shipped scripts (the installer's own
DOWNLOAD_URL assignment is eval'd, the stage-toolcache.sh tool_url() arm is
extracted verbatim and invoked), never duplicated as strings here, so the
tests cannot rot.

CI evidence for the port: run 39129344307, job build-amd64-heavy died 3×
with FH_JAVA_GRADLE_INSTALL_FAILED — curl (35) mid-transfer of
gradle-9.8.1.bin from the SDKMAN CDN. The mirror removes the transient
public-CDN egress from this stage entirely.

Baseline: be94b6b — the last commit whose java-gradle installer still ran
``sdk install gradle``. ``test_baseline_anchor_is_released`` fails while
HEAD == baseline (i.e. before the port commit lands); this is by design,
the same convention as the sibling module's non-self-reference guard.

Pinned here:
  (a) routing     — the download_direct invocation with the canonical
                    services.gradle.org URL, extract=false (zip tree; the
                    shared helper's extract branch is tar-only and is NOT
                    touched), and the SDKMAN candidate layout the generated
                    image resolves (current/bin/gradle). Both fail-closed
                    tokens present; no `sdk install` literal; no bare curl
                    INVOCATION; the unzip precondition names the binary.
  (b) cache key   — the installer-built URL == tool_url('gradle', pin, arch)
                    BYTE-EXACT for BOTH arches — download_direct keys
                    /opt/toolcache as $TOOLCACHE_DIR/gradle/$(basename
                    "$url"), so a mismatch silently never hits the mirror.
  (c) digests     — checksums.json: pinned_version == versions.json pin,
                    64-hex, and amd64 == arm64 (SINGLE architecture-
                    independent -bin.zip — tinytex precedent — asserted).
  (d) list rows   — ``--mode list`` emits a gradle row per arch carrying the
                    (b) basename and the (c) digest.
  (e) fail-closed — the real installer, run in a sandbox with neither the
                    helper stack nor an SDKMAN fallback, exits 1 naming the
                    exact failure token (never a silent 127, never `done`).
"""

import json
import os
import re
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
INSTALLER = REPO / "features" / "java-gradle" / "install.sh"
STAGE_SCRIPT = REPO / "scripts" / "stage-toolcache.sh"

# Immutable anchor: the last commit before the download_direct port. NEVER
# re-point this at HEAD (test_baseline_anchor_is_released pins it).
BASELINE_SHA = "be94b6b"

ARCHES = ("amd64", "arm64")
PIN = "9.8.1"
URL_BASE = f"gradle-{PIN}-bin.zip"
CANONICAL = f"https://services.gradle.org/distributions/{URL_BASE}"


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


def _git_show(path, rev=BASELINE_SHA):
    return subprocess.run(
        ["git", "-C", str(REPO), "show", f"{rev}:{path}"],
        check=True, capture_output=True, text=True,
    ).stdout


def _rev_parse(rev):
    return subprocess.run(
        ["git", "-C", str(REPO), "rev-parse", rev],
        check=True, capture_output=True, text=True,
    ).stdout.strip()


def _versions():
    return json.loads(_text(REPO / "versions.json"))["tools"]


def _checksums(text=None):
    raw = _text(REPO / "checksums.json") if text is None else text
    return json.loads(raw)["tools"]


# ---------------------------------------------------------------------------
# property helpers (pure; runnable against the worktree AND baseline blobs)
# ---------------------------------------------------------------------------

def _installer_url(installer_path, version=None):
    """Full URL the installer actually builds: eval its DOWNLOAD_URL
    assignment (whitespace-tolerant — column-0-anchored greps pass
    vacuously on indented assignments, the starship lesson). Gradle is
    architecture-independent, so there is no case-mapping to eval; VERSION
    is the only input."""
    script = (
        'eval "$(grep -m1 \'^[[:space:]]*DOWNLOAD_URL=\' "$INSTALLER")"; '
        'printf \'%s\\n\' "$DOWNLOAD_URL"'
    )
    env = dict(os.environ, INSTALLER=str(installer_path),
               VERSION=version if version is not None else _versions()["gradle"])
    r = subprocess.run([_bash(), "-c", script], env=env,
                       capture_output=True, text=True, check=True)
    return r.stdout.strip()


def _installer_basename(installer_path):
    """Basename of the URL the installer builds ('' when it assigns none —
    the SDKMAN-era blob)."""
    try:
        return _installer_url(installer_path).rsplit("/", 1)[-1]
    except subprocess.CalledProcessError:
        return ""
    # (no assignment -> grep empty -> eval no-op -> URL unset -> prints "")


def _tool_url(arch, script_path=None):
    """tool_url('gradle', pin, arch) extracted VERBATIM from the given
    stage-toolcache.sh and invoked. Empty when the script has no gradle arm
    (its ``*) return 1`` fallback)."""
    ver = _versions()["gradle"]
    script = (
        'eval "$(sed -n \'/^tool_url() {/,/^}/p\' "$SCRIPT")" || true; '
        'out="$(tool_url gradle "$VER" "$ARCH")" || true; '
        'printf \'%s\\n\' "$out"'
    )
    env = dict(os.environ, SCRIPT=str(script_path or STAGE_SCRIPT),
               VER=ver, ARCH=arch)
    r = subprocess.run([_bash(), "-c", script], env=env,
                       capture_output=True, text=True, check=True)
    return r.stdout.strip()


# ---------------------------------------------------------------------------
# anchor
# ---------------------------------------------------------------------------

def test_baseline_anchor_is_released():
    """The port is committed and the baseline really is the SDKMAN form."""
    assert _rev_parse("HEAD") != _rev_parse(BASELINE_SHA), \
        "anchor test is only meaningful once the port is committed"
    anc = subprocess.run(
        ["git", "-C", str(REPO), "merge-base", "--is-ancestor",
         BASELINE_SHA, "HEAD"], check=False)
    assert anc.returncode == 0, "BASELINE_SHA is not an ancestor of HEAD"
    assert "sdk install gradle" in _git_show("features/java-gradle/install.sh")
    assert "sdk install" not in _text(INSTALLER)


# ---------------------------------------------------------------------------
# (a) routing
# ---------------------------------------------------------------------------

def test_installer_routes_through_download_direct_with_extract_false():
    text = _text(INSTALLER)
    assert re.search(
        r'download_direct\s+"\$DOWNLOAD_URL"\s+"gradle"\s+"\$VERSION"\s+'
        r'"\$SCRATCH_DIR"\s+false', text), \
        "download_direct call shape changed (extract MUST stay false — the " \
        "payload is a zip TREE; the shared helper's extract branch is " \
        "tar-only single-binary; the feature owns the unzip below it)"
    assert "FH_VERSION_UNRESOLVED" in text
    assert "FH_JAVA_GRADLE_INSTALL_FAILED" in text
    assert "FH_JAVA_GRADLE_NOT_AVAILABLE" in text
    assert 'command -v download_direct' in text


def test_installer_keeps_the_sdkman_candidate_layout_the_image_resolves():
    """The generated image resolves gradle from
    ~/.sdkman/candidates/gradle/current/bin (dockerfile_template.j2 PATH and
    profile.d); the port MUST NOT move that contract."""
    text = _text(INSTALLER)
    assert 'GRADLE_CANDIDATE_DIR="${HOME_DIR}/.sdkman/candidates/gradle"' in text
    assert re.search(r'unzip\s+-oq\s+"\$\{SCRATCH_DIR\}/gradle"\s+-d\s+"\$\{GRADLE_CANDIDATE_DIR\}"', text)
    assert 'ln -sfn "gradle-${VERSION}" "${GRADLE_CANDIDATE_DIR}/current"' in text
    assert '[ ! -x "${GRADLE_CANDIDATE_DIR}/current/bin/gradle" ]' in text


def test_unzip_precondition_is_explicit_and_fail_loud():
    """Step-0 decision: unzip presence in the base image is NOT provable
    from repository evidence (it is in no apt list; the only unconditional
    zip user, quarto-chromium, installs it itself). So the installer must
    ENSURE it and fail loud by name — never a cryptic 127 mid-unzip."""
    text = _text(INSTALLER)
    assert "command -v unzip" in text
    assert re.search(r'apt_install unzip', text), \
        "unzip must be ensured via the project's own apt helper (quarto-chromium precedent)"
    # the guard AFTER the ensure attempt must name the missing binary
    assert re.search(r'FH_JAVA_GRADLE_INSTALL_FAILED[^\n]*unzip is not available', text)


def test_installer_contains_no_sdkman_transport():
    text = _text(INSTALLER)
    # A curl INVOCATION (flag follows); prose like "curl (35)" does not match.
    assert re.search(r'\bcurl\b\s+-', text) is None
    assert "sdk install" not in text
    assert "get.sdkman.io" not in text
    assert "sdkman.ai" not in text


def test_red_proof_baseline_did_route_through_sdk(tmp_path):
    """(a) is not vacuous: the baseline blob fails the predicates above."""
    old = tmp_path / "install_old.sh"
    old.write_text(_git_show("features/java-gradle/install.sh"), encoding="utf-8")
    text = _text(old)
    assert "sdk install gradle" in text
    assert "download_direct" not in text


# ---------------------------------------------------------------------------
# (b) cache-key parity (download_direct: $TOOLCACHE_DIR/$tool/$(basename "$url"))
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("arch", ARCHES)
def test_installer_and_stager_build_the_same_url_byte_exact(arch):
    url = _installer_url(INSTALLER)
    assert url == CANONICAL, \
        "installer URL drifted from the canonical publisher endpoint"
    assert _tool_url(arch) == url, \
        f"stager tool_url('gradle', pin, {arch}) diverged from the installer " \
        "URL — the mirror key would silently never hit"


@pytest.mark.parametrize("arch", ARCHES)
def test_red_proof_baseline_shares_no_cache_key_with_the_stager(tmp_path, arch):
    """(b) is not vacuous: the baseline installer builds NO download_direct
    URL at all, so the mirror could never have served it."""
    old = tmp_path / "install_old.sh"
    old.write_text(_git_show("features/java-gradle/install.sh"), encoding="utf-8")
    assert _installer_basename(old) == ""


def test_red_proof_baseline_stager_had_no_gradle_arm(tmp_path):
    old = tmp_path / "stage-baseline.sh"
    old.write_text(_git_show("scripts/stage-toolcache.sh"), encoding="utf-8")
    for arch in ARCHES:
        assert _tool_url(arch, script_path=old) == ""


# ---------------------------------------------------------------------------
# (c) digests
# ---------------------------------------------------------------------------

def test_checksums_block_is_complete_and_arch_independent():
    blk = _checksums()["gradle"]
    assert blk["pinned_version"] == _versions()["gradle"] == PIN
    amd = blk["checksums"][PIN]["amd64"]
    arm = blk["checksums"][PIN]["arm64"]
    for digest in (amd, arm):
        assert re.fullmatch(r"[0-9a-f]{64}", digest), digest
    # The -bin.zip is a SINGLE architecture-independent asset (tinytex
    # precedent): any future divergence means the staging assumption broke.
    assert amd == arm, \
        "gradle digests diverged per-arch — services.gradle.org serves ONE " \
        "-bin.zip for both arches; investigate before touching this test"
    # And the stager must agree with the installer on that single asset.
    assert _installer_url(INSTALLER) == CANONICAL


def test_red_proof_baseline_checksums_lacked_gradle():
    """(c) is not vacuous: the baseline's checksums.json has no gradle block."""
    with pytest.raises(KeyError):
        _checksums(_git_show("checksums.json"))["gradle"]


# ---------------------------------------------------------------------------
# (d) staging list rows
# ---------------------------------------------------------------------------

def test_list_mode_emits_gradle_rows_with_matching_digests():
    env = dict(os.environ,
               VERSIONS_FILE=str(REPO / "versions.json"),
               CHECKSUMS_FILE=str(REPO / "checksums.json"))
    r = subprocess.run(
        [_bash(), str(STAGE_SCRIPT), "--mode", "list", "--arch", "amd64,arm64"],
        capture_output=True, text=True, env=env, cwd=str(REPO), check=False)
    assert r.returncode == 0, r.stderr
    rows = [ln for ln in r.stdout.splitlines()
            if re.search(r"(^|\t)gradle(\t|$)", ln)]
    assert len(rows) == 2, rows
    blk = _checksums()["gradle"]["checksums"][PIN]
    for arch in ARCHES:
        row = next(ln for ln in rows if arch in ln)
        assert blk[arch] in row, row
        assert URL_BASE in row, row
    assert "skipping" not in r.stderr, r.stderr


# ---------------------------------------------------------------------------
# (e) runtime fail-closed (the real installer, minimal sandbox)
# ---------------------------------------------------------------------------

def _run_sandboxed(args, tmp_path):
    """Run the real installer with an isolated PATH (no gradle, no sdk, no
    download_direct helper stack) and no SoT reachable from cwd."""
    env = {
        "PATH": f"{tmp_path}:/usr/bin:/bin",
        "GRADLE_VERSION": "",
        "HOME_DIR": str(tmp_path / "home"),
        "NB_USER": "jovyan", "NB_UID": "1001", "NB_GID": "1001",
    }
    env.update(args)
    return subprocess.run(
        [_bash(), str(INSTALLER)], env=env, cwd=str(tmp_path),
        capture_output=True, text=True, check=False)


def test_sandbox_without_helpers_or_version_fails_closed_unresolved(tmp_path):
    """No fh_resolve_version, no artefacts/versions.json, no env pin: the
    installer must name FH_VERSION_UNRESOLVED and exit 1 — never fall back
    to an SDKMAN 'latest' candidate."""
    proc = _run_sandboxed({"GRADLE_VERSION": ""}, tmp_path)
    assert proc.returncode == 1, proc.stdout + proc.stderr
    assert "FH_VERSION_UNRESOLVED" in proc.stderr
    assert "java-gradle: done" not in proc.stdout


def test_sandbox_without_download_direct_fails_loud_never_falls_back(tmp_path):
    """The core anti-regression: with the version pinned but the helper
    stack absent (the CI-failure shape), the installer must exit 1 naming
    FH_JAVA_GRADLE_INSTALL_FAILED. The SDKMAN-era form printed the curl
    (35) chain and died with the SAME token — but only after three network
    attempts; this path never touches the network and never reaches
    `sdk install`."""
    proc = _run_sandboxed({"GRADLE_VERSION": PIN}, tmp_path)
    assert proc.returncode == 1, proc.stdout + proc.stderr
    assert "FH_JAVA_GRADLE_INSTALL_FAILED" in proc.stderr
    assert "download_direct helper not found" in proc.stderr
    assert "java-gradle: done" not in proc.stdout
