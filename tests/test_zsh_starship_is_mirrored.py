"""Regression guard: zsh-config installs starship from the PINNED, digest-
verified toolcache mirror path — never via the piped
``curl https://starship.rs/install.sh | sh`` form again.

Sibling of tests/test_container_tools_are_mirrored.py, same discipline: the
predicates evaluate the REAL shipped scripts (the installer's own case-mapping
and DOWNLOAD_URL assignment are eval'd, the stage-toolcache.sh tool_url() arm
is extracted verbatim and invoked), never duplicated as strings here, so the
tests cannot rot.

Baseline: 6ffe215 — the last commit whose zsh-config installer still fetched
the unpinned upstream installer. ``test_baseline_anchor_is_released`` fails
while HEAD == baseline (i.e. before the port commit lands); this is by design,
the same convention as the sibling module's non-self-reference guard.

Pinned here:
  (a) routing     — the download_direct invocation with the install dir
                    ${HOME_DIR}/.local/bin (feature.json postInstallCheck's
                    exact path) and extract=true; no bare curl INVOCATION, no
                    starship.rs/install.sh, no 'releases/latest'; both
                    fail-closed tokens present.
  (b) cache key   — basename of the installer-built URL == basename of
                    tool_url('starship', pin, arch), BOTH arches — download_direct
                    keys /opt/toolcache as $TOOLCACHE_DIR/starship/$(basename
                    "$url"), so a mismatch silently never hits the mirror.
  (c) digests     — checksums.json block: pinned_version == versions.json pin,
                    64-hex digests for BOTH arches.
  (d) list rows   — ``--mode list`` emits a starship row per arch carrying the
                    (b) URL basename and the (c) digest.
"""

import json
import os
import re
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
INSTALLER = REPO / "features" / "zsh-config" / "install.sh"
STAGE_SCRIPT = REPO / "scripts" / "stage-toolcache.sh"

# Immutable anchor: the last commit before the download_direct port. NEVER
# re-point this at HEAD (test_baseline_anchor_is_released pins it).
BASELINE_SHA = "6ffe215"

ARCHES = ("amd64", "arm64")
RELEASE_ARCH = {"amd64": "x86_64", "arm64": "aarch64"}
PIN = "1.27.0"


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

def _installer_basename(installer_path):
    """Basename of the URL the installer actually builds: eval its
    ``case "${ARCH}"`` mapping and its DOWNLOAD_URL assignment. Leading
    whitespace tolerated — the block lives inside the starship-missing if.
    VERSION/ARCH come from the environment."""
    script = (
        'eval "$(sed -n \'/^[[:space:]]*case "/,/^[[:space:]]*esac/p\' "$INSTALLER")"; '
        'eval "$(grep -m1 \'^[[:space:]]*DOWNLOAD_URL=\' "$INSTALLER")"; '
        'printf \'%s\\n\' "${DOWNLOAD_URL##*/}"'
    )
    env = dict(os.environ, INSTALLER=str(installer_path))
    r = subprocess.run([_bash(), "-c", script], env=env,
                       capture_output=True, text=True, check=True)
    return r.stdout.strip()


def _installer_url(installer_path, arch):
    """Full installer-built URL for one dpkg arch (VERSION = versions.json pin,
    the same SoT matrix() reads)."""
    env_version = _versions()["starship"]
    script = (
        'eval "$(sed -n \'/^[[:space:]]*case "/,/^[[:space:]]*esac/p\' "$INSTALLER")"; '
        'eval "$(grep -m1 \'^[[:space:]]*DOWNLOAD_URL=\' "$INSTALLER")"; '
        'printf \'%s\\n\' "$DOWNLOAD_URL"'
    )
    env = dict(os.environ, INSTALLER=str(installer_path),
               VERSION=env_version, ARCH=arch)
    r = subprocess.run([_bash(), "-c", script], env=env,
                       capture_output=True, text=True, check=True)
    return r.stdout.strip()


def _tool_url_basename(arch, script_path=None):
    """Basename of tool_url('starship', pin, arch), tool_url() extracted
    VERBATIM from the given stage-toolcache.sh and invoked. Empty when the
    script has no starship arm (its ``*) return 1`` fallback)."""
    ver = _versions()["starship"]
    script = (
        'eval "$(sed -n \'/^tool_url() {/,/^}/p\' "$SCRIPT")" || true; '
        'out="$(tool_url starship "$VER" "$ARCH")" || true; '
        'printf \'%s\\n\' "${out##*/}"'
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
    """The port is committed and the baseline really is the piped-curl form."""
    assert _rev_parse("HEAD") != _rev_parse(BASELINE_SHA), \
        "anchor test is only meaningful once the port is committed"
    anc = subprocess.run(
        ["git", "-C", str(REPO), "merge-base", "--is-ancestor",
         BASELINE_SHA, "HEAD"], check=False)
    assert anc.returncode == 0, "BASELINE_SHA is not an ancestor of HEAD"
    assert "starship.rs/install.sh" in _git_show("features/zsh-config/install.sh")
    assert "starship.rs/install.sh" not in _text(INSTALLER)


# ---------------------------------------------------------------------------
# (a) routing
# ---------------------------------------------------------------------------

def test_installer_routes_through_download_direct_to_the_contract_path():
    text = _text(INSTALLER)
    assert re.search(
        r'download_direct\s+"\$DOWNLOAD_URL"\s+"starship"\s+"\$VERSION"\s+'
        r'"\$\{HOME_DIR\}/\.local/bin"\s+true', text), \
        "download_direct call shape changed (install dir must stay " \
        "${HOME_DIR}/.local/bin — feature.json postInstallCheck; extract=true " \
        "— the tarball holds the executable at its root)"
    assert "FH_VERSION_UNRESOLVED" in text
    assert "FH_STARSHIP_INSTALL_FAILED" in text
    assert 'command -v download_direct' in text


def test_installer_contains_no_piped_upstream_form():
    text = _text(INSTALLER)
    # A curl INVOCATION (flag follows); prose like "curl (35)" does not match.
    assert re.search(r'\bcurl\b\s+-', text) is None
    assert "starship.rs/install.sh" not in text
    assert "releases/latest" not in text


def test_red_proof_baseline_did_route_through_the_piped_form(tmp_path):
    """(a) is not vacuous: the baseline blob fails the predicates above."""
    old = tmp_path / "install_old.sh"
    old.write_text(_git_show("features/zsh-config/install.sh"), encoding="utf-8")
    text = _text(old)
    assert "starship.rs/install.sh" in text
    assert "download_direct" not in text
    assert re.search(r'\bcurl\b\s+-', text) is not None


# ---------------------------------------------------------------------------
# (b) cache-key parity (download_direct: $TOOLCACHE_DIR/$tool/$(basename "$url"))
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("arch", ARCHES)
def test_installer_and_stager_build_the_same_cache_key(arch):
    url = _installer_url(INSTALLER, arch)
    assert url == (
        "https://github.com/starship/starship/releases/download/"
        f"v{PIN}/starship-{RELEASE_ARCH[arch]}-unknown-linux-musl.tar.gz")
    base_installer = url.rsplit("/", 1)[-1]
    base_stager = _tool_url_basename(arch)
    assert base_installer == base_stager == \
        f"starship-{RELEASE_ARCH[arch]}-unknown-linux-musl.tar.gz"


@pytest.mark.parametrize("arch", ARCHES)
def test_red_proof_baseline_shares_no_cache_key_with_the_stager(tmp_path, arch):
    """(b) is not vacuous: the baseline installer builds NO download_direct
    URL at all, so the mirror could never have served it."""
    old = tmp_path / "install_old.sh"
    old.write_text(_git_show("features/zsh-config/install.sh"), encoding="utf-8")
    assert _installer_basename(old) == ""


def test_red_proof_baseline_stager_had_no_starship_arm(tmp_path):
    old = tmp_path / "stage-baseline.sh"
    old.write_text(_git_show("scripts/stage-toolcache.sh"), encoding="utf-8")
    for arch in ARCHES:
        assert _tool_url_basename(arch, script_path=old) == ""


# ---------------------------------------------------------------------------
# (c) digests
# ---------------------------------------------------------------------------

def test_checksums_block_is_complete_for_both_arches():
    blk = _checksums()["starship"]
    assert blk["pinned_version"] == _versions()["starship"] == PIN
    for arch in ARCHES:
        digest = blk["checksums"][PIN][arch]
        assert re.fullmatch(r"[0-9a-f]{64}", digest), (arch, digest)


def test_red_proof_baseline_checksums_lacked_starship():
    """(c) is not vacuous: the baseline's checksums.json has no starship block."""
    with pytest.raises(KeyError):
        _checksums(_git_show("checksums.json"))["starship"]


# ---------------------------------------------------------------------------
# (d) staging list rows
# ---------------------------------------------------------------------------

def test_list_mode_emits_starship_rows_with_matching_digests():
    env = dict(os.environ,
               VERSIONS_FILE=str(REPO / "versions.json"),
               CHECKSUMS_FILE=str(REPO / "checksums.json"))
    r = subprocess.run(
        [_bash(), str(STAGE_SCRIPT), "--mode", "list", "--arch", "amd64,arm64"],
        capture_output=True, text=True, env=env, cwd=str(REPO), check=False)
    assert r.returncode == 0, r.stderr
    rows = [ln for ln in r.stdout.splitlines()
            if re.search(r"(^|\t)starship(\t|$)", ln)]
    assert len(rows) == 2, rows
    blk = _checksums()["starship"]["checksums"][PIN]
    for arch in ARCHES:
        row = next(ln for ln in rows if arch in ln)
        assert blk[arch] in row, row
        assert f"starship-{RELEASE_ARCH[arch]}-unknown-linux-musl.tar.gz" in row, row
    assert "skipping" not in r.stderr, r.stderr
