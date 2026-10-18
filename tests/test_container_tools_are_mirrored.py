"""Regression tests: hadolint/ctop/dive are mirrored through the toolcache.

WHY THIS FILE EXISTS. CI run 39120654609's build-amd64-heavy leg died on
``curl: (35) Recv failure: Connection reset by peer`` against un-mirrored
GitHub release assets (hadolint bake #1, ctop bakes #2-#3) while the six
already-mirrored tools hit flat cache paths with ``expected=6 present=6
missing=0``. The fix converts the three installers from bare ``curl`` to
``download_direct`` (digest-pinned toolcache), adds their URL arms to
tool_url() and both-arch digests to checksums.json, raising the staging
matrix from 6 to 9 rows per arch.

WHAT IS GUARDED (each with a red proof against the pre-change content, via
``git show HEAD:<path>`` — a property that also held against HEAD would be a
vacuous test):

  (a) routing     — the installer calls download_direct with the canonical
                    5-arg form and contains no bare ``curl -…`` of the asset.
  (b) key match   — the cache key download_direct reads
                    ($TOOLCACHE_DIR/$tool/$(basename "$url")) equals the
                    basename stage-toolcache.sh stages. Both sides are
                    EVALUATED from the real scripts (tool_url() extracted
                    and invoked; the installer's ``case``-mapping +
                    DOWNLOAD_URL assignment eval'd), never duplicated as
                    strings here, so the test cannot rot.
  (c) digests     — each checksums.json block carries pinned_version,
                    archive_format and digests for BOTH arches (a missing
                    arch makes matrix() silently skip it, see the
                    'no … digest … skipping' warning path).
  (d) breadth     — ``--mode list --arch amd64,arm64`` yields 9 rows/arch.
  (e) fail-closed — unresolved version exits 1 with FH_VERSION_UNRESOLVED;
                    no upstream 'latest' fallback (checksum-pinned tools).
"""

import json
import os
import re
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
STAGE_SCRIPT = REPO / "scripts" / "stage-toolcache.sh"

TOOLS = ("hadolint", "ctop", "dive")
ALL_NINE = ("kubectl", "helm", "kustomize", "k9s", "tilt", "tinytex",
            "hadolint", "ctop", "dive")
ARCHES = ("amd64", "arm64")


def _installer(tool):
    return REPO / "features" / tool / "install.sh"


def _text(path):
    return path.read_text(encoding="utf-8")


def _git_show(path):
    """HEAD blob of a repo-relative path (pre-change content)."""
    return subprocess.run(
        ["git", "-C", str(REPO), "show", f"HEAD:{path}"],
        check=True, capture_output=True, text=True,
    ).stdout


def _bash():
    for cand in ("/opt/homebrew/bin/bash", "/usr/local/bin/bash", "/bin/bash"):
        if os.path.exists(cand):
            r = subprocess.run([cand, "-c", 'echo "${BASH_VERSINFO[0]}"'],
                               capture_output=True, text=True, check=False)
            if r.returncode == 0 and int(r.stdout.strip()) >= 4:
                return cand
    pytest.skip("bash >= 4 not available")


def _versions():
    return json.loads(_text(REPO / "versions.json"))["tools"]


def _checksums(text=None):
    if text is None:
        return json.loads(_text(REPO / "checksums.json"))["tools"]
    return json.loads(text)["tools"]


# ---------------------------------------------------------------------------
# Property helpers (pure, so the same predicate can be run against the
# current worktree AND the HEAD blob for the red proofs).
# ---------------------------------------------------------------------------

def _routes_via_download_direct(text, tool):
    return re.search(
        rf'download_direct\s+"\$DOWNLOAD_URL"\s+"{tool}"\s+"\$VERSION"\s+'
        r'"/usr/local/bin"\s+(?:true|false)', text) is not None


def _has_bare_curl(text):
    """A curl INVOCATION (flag follows). Comments like 'a bare curl (tilt/gh
    precedent)' do not match."""
    return re.search(r'\bcurl\b\s+-', text) is not None


def _installer_basename(tool, arch):
    """Basename of the URL the installer actually builds: eval its
    ``case "${ARCH}"`` mapping and DOWNLOAD_URL assignment with VERSION
    taken from versions.json — the same SoT matrix() reads."""
    ver = _versions()[tool]
    script = (
        'eval "$(sed -n \'/^case "/,/^esac/p\' "$INSTALLER")"; '
        'eval "$(grep -m1 \'^DOWNLOAD_URL=\' "$INSTALLER")"; '
        'printf \'%s\\n\' "${DOWNLOAD_URL##*/}"'
    )
    env = dict(os.environ, VERSION=ver, ARCH=arch, INSTALLER=str(_installer(tool)))
    r = subprocess.run([_bash(), "-c", script], env=env,
                       capture_output=True, text=True, check=True)
    return r.stdout.strip()


def _tool_url_basename(script_path, tool, arch):
    """Basename of tool_url() output, with tool_url() extracted VERBATIM
    from the given stage-toolcache.sh file and invoked. Empty when the
    script has no arm for the tool (its ``*) return 1`` arm)."""
    ver = _versions()[tool]
    script = (
        'eval "$(sed -n \'/^tool_url() {/,/^}/p\' "$SCRIPT")" || true; '
        'out="$(tool_url "$TOOL" "$VER" "$ARCH")" || true; '
        'printf \'%s\\n\' "${out##*/}"'
    )
    env = dict(os.environ, SCRIPT=str(script_path), TOOL=tool, VER=ver, ARCH=arch)
    r = subprocess.run([_bash(), "-c", script], env=env,
                       capture_output=True, text=True, check=True)
    return r.stdout.strip()


def _list_rows(script_path):
    """Run --mode list --arch amd64,arm64, return {arch: [tool,...]} and
    stderr. Env-overridable SoT paths keep HEAD-blob copies runnable."""
    env = dict(os.environ,
               VERSIONS_FILE=str(REPO / "versions.json"),
               CHECKSUMS_FILE=str(REPO / "checksums.json"))
    r = subprocess.run(
        [_bash(), str(script_path), "--mode", "list", "--arch", "amd64,arm64"],
        capture_output=True, text=True, env=env, cwd=str(REPO), check=False)
    assert r.returncode == 0, r.stderr
    rows = {}
    for line in r.stdout.strip().splitlines()[1:]:  # drop TSV header
        cols = line.split("\t")
        rows.setdefault(cols[1], []).append(cols[0])
    return rows, r.stderr


def _digests_complete(blocks, tool):
    blk = blocks[tool]
    ver = blk["pinned_version"]
    assert blk["archive_format"]
    per_arch = blk["checksums"][ver]
    for arch in ARCHES:
        assert re.fullmatch(r"[0-9a-f]{64}", per_arch[arch])
    return True


# ---------------------------------------------------------------------------
# (a) routing
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("tool", TOOLS)
def test_installer_routes_through_download_direct(tool):
    text = _text(_installer(tool))
    assert _routes_via_download_direct(text, tool), \
        f"{tool}: no canonical 5-arg download_direct call"
    assert not _has_bare_curl(text), f"{tool}: bare curl of a release asset"


@pytest.mark.parametrize("tool", TOOLS)
def test_red_proof_old_installer_used_bare_curl(tool):
    """(a) is not vacuous: against HEAD the predicate is inverted — bare
    curl present, download_direct absent."""
    old = _git_show(f"features/{tool}/install.sh")
    assert _has_bare_curl(old), f"{tool}: HEAD had no bare curl — guard vacuous"
    assert not _routes_via_download_direct(old, tool)


# ---------------------------------------------------------------------------
# (b) cache-key basename match (the classic silent miss: staged under one
#     name, read under another -> download_direct misses every build)
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("tool", TOOLS)
@pytest.mark.parametrize("arch", ARCHES)
def test_cache_key_basenames_match(tool, arch):
    staged = _tool_url_basename(STAGE_SCRIPT, tool, arch)
    read = _installer_basename(tool, arch)
    assert staged and staged == read, \
        f"{tool}@{arch}: staged '{staged}' != read '{read}'"


@pytest.mark.parametrize("tool", TOOLS)
@pytest.mark.parametrize("arch", ARCHES)
def test_red_proof_old_script_knew_no_arm(tool, arch, tmp_path):
    """(b) is not vacuous: HEAD's tool_url() has no arm for these tools,
    so the staged basename is empty and the same assertion fails."""
    old = tmp_path / "stage-head.sh"
    old.write_text(_git_show("scripts/stage-toolcache.sh"), encoding="utf-8")
    assert _tool_url_basename(old, tool, arch) == ""


# ---------------------------------------------------------------------------
# (c) both-arch digests
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("tool", TOOLS)
def test_checksums_block_has_both_arch_digests(tool):
    _digests_complete(_checksums(), tool)


@pytest.mark.parametrize("tool", TOOLS)
def test_red_proof_old_checksums_lacked_the_tool(tool):
    """(c) is not vacuous: HEAD's checksums.json has no complete block for
    the tool at all."""
    with pytest.raises((KeyError, AssertionError)):
        _digests_complete(_checksums(_git_show("checksums.json")), tool)


# ---------------------------------------------------------------------------
# (d) staging breadth: 9 rows/arch, no silent skips
# ---------------------------------------------------------------------------

def test_list_mode_reports_nine_rows_per_arch():
    rows, stderr = _list_rows(STAGE_SCRIPT)
    assert set(rows) == set(ARCHES), rows
    for arch in ARCHES:
        assert sorted(rows[arch]) == sorted(ALL_NINE), \
            f"{arch}: {len(rows[arch])} rows, expected 9"
    assert "skipping" not in stderr, stderr


def test_red_proof_old_script_staged_only_six(tmp_path):
    """(d) is not vacuous: HEAD's script stages 6 rows/arch (its TOOLS list
    lacks the three tools even against the CURRENT SoT files)."""
    old = tmp_path / "stage-head.sh"
    old.write_text(_git_show("scripts/stage-toolcache.sh"), encoding="utf-8")
    rows, _ = _list_rows(old)
    for arch in ARCHES:
        assert sorted(rows[arch]) != sorted(ALL_NINE)
        assert len(rows[arch]) == 6, rows


# ---------------------------------------------------------------------------
# (e) fail-closed version resolution
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("tool", TOOLS)
def test_installer_fails_closed_on_unresolved_version(tool, tmp_path):
    text = _text(_installer(tool))
    assert "FH_VERSION_UNRESOLVED" in text
    assert "releases/latest" not in text  # no 'latest' fallback for pinned tools
    # Runtime: empty cwd (no artefacts/versions.json, no helper sourcing)
    # and a PATH without jq/dpkg/curl — the resolver must exit 1 with the
    # marker BEFORE any download could be attempted.
    empty_bin = tmp_path / "bin"
    empty_bin.mkdir()
    env = dict(os.environ, PATH=str(empty_bin), FEATURE_HELPERS_DIR="")
    r = subprocess.run([_bash(), str(_installer(tool))], cwd=tmp_path,
                       env=env, capture_output=True, text=True, check=False)
    assert r.returncode != 0
    assert "FH_VERSION_UNRESOLVED" in r.stderr


@pytest.mark.parametrize("tool", TOOLS)
def test_red_proof_old_installer_had_no_unresolved_guard(tool):
    old = _git_show(f"features/{tool}/install.sh")
    assert "FH_VERSION_UNRESOLVED" not in old
