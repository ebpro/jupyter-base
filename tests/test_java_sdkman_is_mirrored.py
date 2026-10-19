"""Regression guard: java-sdkman bootstraps SDKMAN from the PINNED, digest-
verified toolcache mirror — never by piping the upstream bootstrap script again.

Sibling of tests/test_java_gradle_is_mirrored.py and tests/test_zsh_starship_is_
mirrored.py, same discipline: the predicates evaluate the REAL shipped scripts
(the installer's own DOWNLOAD_URL assignment is eval'd, the stage-toolcache.sh
tool_url() arm is extracted verbatim and invoked), never duplicated as strings
here, so the tests cannot rot.

CI evidence for the port: run 39053927880 (and the dead legs of 39179490232) —
``build-arm64`` died with FH_SDKMAN_INSTALL_FAILED on ``curl: (35) Recv failure:
Connection reset by peer``. The failing fetch was NOT ours: it was performed by
the bootstrap SCRIPT we piped into bash, which downloads its own archive at
build time. That archive is a byte-identical GitHub release asset, so pinning
it removes the egress without changing what gets installed (5.23.2 is what the
broker serves today; the digest matches through the broker's own 302).

The port is only correct if the seven things the bootstrap script synthesised
AROUND that archive are reproduced, because the release zip ships ONLY bin/,
src/ and contrib/ — no etc/, no var/. A zip that unpacks and leaves those
behind yields an SDKMAN that sources but cannot install, which is precisely the
silent break this file exists to prevent:

  1. the directory skeleton (ext/ is find'ed unconditionally by
     sdkman-init.sh; candidates/ backs SDKMAN_CANDIDATES_DIR);
  2. var/platform           (read at sdkman-init.sh source time; LOWERCASE
                             tokens — the API rejects LINUX64);
  3. var/candidates         (read unconditionally: SDKMAN_CANDIDATES_CSV=$(<...));
  4. etc/config             (all 13 keys, ci=true resolved, selfupdate off);
  5. var/version;
  6. var/version_native     (compared with `<`, which errors on a missing file);
  7. extract + flatten, no --strip-components.

Deliberately NOT reproduced (pinned below so a future "fix" cannot re-add them
silently): rc-file mutation, the native CLI, the existing-install guard.

Baseline: fc02997 — the last commit whose java-sdkman installer still piped the
bootstrap script. ``test_baseline_anchor_is_released`` fails while HEAD ==
baseline (i.e. before the port commit lands); this is by design, the same
convention as the sibling modules' non-self-reference guard.
"""

import json
import os
import re
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
INSTALLER = REPO / "features" / "java-sdkman" / "install.sh"
FEATURE_JSON = REPO / "features" / "java-sdkman" / "feature.json"
STAGE_SCRIPT = REPO / "scripts" / "stage-toolcache.sh"

# Immutable anchor: the last commit before the download_direct port. NEVER
# re-point this at HEAD (test_baseline_anchor_is_released pins it).
BASELINE_SHA = "fc02997"

TOOL = "sdkman-cli"
ARCHES = ("amd64", "arm64")
PIN = "5.23.2"
BASENAME = f"sdkman-cli-{PIN}.zip"
CANONICAL = f"https://github.com/sdkman/sdkman-cli/releases/download/{PIN}/{BASENAME}"

#: The 15-key claim in the design brief is wrong: the bootstrap script writes
#: 13 (verified against the fetched-and-read script, never executed). Pinned
#: verbatim, in the script's own emission order, with ci=true resolved.
CONFIG_KEYS = (
    "sdkman_auto_answer=true",
    "sdkman_colour_enable=false",
    "sdkman_selfupdate_feature=false",
    "sdkman_auto_complete=true",
    "sdkman_auto_env=false",
    "sdkman_beta_channel=false",
    "sdkman_checksum_enable=true",
    "sdkman_curl_connect_timeout=7",
    "sdkman_curl_max_time=10",
    "sdkman_debug_mode=false",
    "sdkman_healthcheck_enable=true",
    "sdkman_insecure_ssl=false",
    "sdkman_native_enable=true",
)

#: The synthesised files the archive does not contain.
SYNTHESISED = ("var/platform", "var/candidates", "etc/config", "var/version", "var/version_native")


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


def _code(path):
    """Executable lines only (whole-line comments dropped).

    This installer documents what it deliberately does NOT do — no rc mutation,
    no native CLI, no --strip-components, no `curl -s` seed — and those prose
    mentions must not satisfy or defeat an absence assertion. Prose is checked
    separately by the grep gate in the report; behaviour is checked here.
    """
    return "\n".join(
        ln for ln in _text(path).splitlines() if not ln.lstrip().startswith("#")
    )


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
    assignment (whitespace-tolerant — column-0-anchored greps pass vacuously
    on indented assignments, the starship lesson)."""
    script = (
        'eval "$(grep -m1 \'^[[:space:]]*DOWNLOAD_URL=\' "$INSTALLER")"; '
        'printf \'%s\\n\' "$DOWNLOAD_URL"'
    )
    env = dict(os.environ, INSTALLER=str(installer_path),
               SDKMAN_CLI_VERSION=version if version is not None else _versions()[TOOL])
    r = subprocess.run([_bash(), "-c", script], env=env,
                       capture_output=True, text=True, check=True)
    return r.stdout.strip()


def _installer_basename(installer_path):
    """Basename of the URL the installer builds ('' when it assigns none — the
    bootstrap-script-era blob, which fetched nothing of its own)."""
    try:
        return _installer_url(installer_path).rsplit("/", 1)[-1]
    except subprocess.CalledProcessError:
        return ""


def _tool_url(arch, script_path=None):
    """tool_url('sdkman-cli', pin, arch) extracted VERBATIM from the given
    stage-toolcache.sh and invoked. Empty when the script has no sdkman-cli arm
    (its ``*) return 1`` fallback)."""
    ver = _versions()[TOOL]
    script = (
        'eval "$(sed -n \'/^tool_url() {/,/^}/p\' "$SCRIPT")" || true; '
        'out="$(tool_url sdkman-cli "$VER" "$ARCH")" || true; '
        'printf \'%s\\n\' "$out"'
    )
    env = dict(os.environ, SCRIPT=str(script_path or STAGE_SCRIPT), VER=ver, ARCH=arch)
    r = subprocess.run([_bash(), "-c", script], env=env,
                       capture_output=True, text=True, check=True)
    return r.stdout.strip()


# ---------------------------------------------------------------------------
# anchor
# ---------------------------------------------------------------------------

def test_baseline_anchor_is_released():
    """The port is committed and the baseline really is the piped-script form."""
    assert _rev_parse("HEAD") != _rev_parse(BASELINE_SHA), \
        "anchor test is only meaningful once the port is committed"
    anc = subprocess.run(
        ["git", "-C", str(REPO), "merge-base", "--is-ancestor",
         BASELINE_SHA, "HEAD"], check=False)
    assert anc.returncode == 0, "BASELINE_SHA is not an ancestor of HEAD"
    assert "get.sdkman.io" in _git_show("features/java-sdkman/install.sh")
    assert "get.sdkman.io" not in _text(INSTALLER)


# ---------------------------------------------------------------------------
# (a) routing
# ---------------------------------------------------------------------------

def test_installer_routes_through_download_direct_with_extract_false():
    text = _text(INSTALLER)
    assert re.search(
        r'download_direct\s+"\$DOWNLOAD_URL"\s+"sdkman-cli"\s+"\$SDKMAN_CLI_VERSION"\s+'
        r'"\$SCRATCH_DIR"\s+false', text), \
        "download_direct call shape changed (extract MUST stay false — the payload is a " \
        "zip TREE and the shared helper's extract branch is tar-only; the feature owns " \
        "the unzip)"
    assert "FH_VERSION_UNRESOLVED" in text
    assert "FH_SDKMAN_INSTALL_FAILED" in text
    assert 'command -v download_direct' in text


def test_installer_declares_zip_and_unzip_and_fails_loud():
    """Neither binary is base-guaranteed (unzip is in no apt list either), and
    a missing `zip` would break `sdk install java` AFTER a successful download.
    The ensure + named guard is the quarto-chromium / java-gradle precedent."""
    text = _text(INSTALLER)
    assert re.search(r'apt_install unzip zip', text), \
        "both must be ensured via the project's own apt helper"
    assert "command -v unzip" in text and "command -v zip" in text
    assert re.search(r'FH_SDKMAN_INSTALL_FAILED[^\n]*unzip is not available', text)
    assert re.search(r'FH_SDKMAN_INSTALL_FAILED[^\n]*zip is not available', text)


def test_installer_contains_no_bootstrap_script_pipe():
    text = _code(INSTALLER)
    # A curl INVOCATION (flag follows); prose like "curl (35)" does not match.
    assert re.search(r'\bcurl\b\s+-', text) is None
    assert "get.sdkman.io" not in text
    assert "| bash" not in text
    assert "|bash" not in text


# ---------------------------------------------------------------------------
# (b) the seven synthesised steps (the archive ships none of them)
# ---------------------------------------------------------------------------

def test_the_archive_only_layout_is_acknowledged():
    """The release zip carries bin/, src/ and contrib/ ONLY. The installer must
    therefore create etc/ and var/ itself — never assume they arrive."""
    text = _text(INSTALLER)
    assert re.search(
        r'mkdir -p "\$SDKMAN_DIR/tmp" "\$SDKMAN_DIR/ext" "\$SDKMAN_DIR/etc" '
        r'"\$SDKMAN_DIR/var" "\$SDKMAN_DIR/candidates"', text), \
        "step 1 (the directory skeleton, incl. ext/ which sdkman-init.sh finds " \
        "unconditionally, and candidates/ which backs SDKMAN_CANDIDATES_DIR) is gone"


def test_platform_tokens_are_the_lowercase_ones():
    """A live probe showed the API rejects LINUX64 with INVALID_PLATFORM."""
    text = _code(INSTALLER)
    assert 'SDKMAN_PLATFORM="linuxx64"' in text
    assert 'SDKMAN_PLATFORM="linuxarm64"' in text
    assert re.search(r'SDKMAN_PLATFORM="(LINUX64|LINUXARM64)"', text) is None
    assert '"$SDKMAN_DIR/var/platform"' in text


def test_config_is_written_verbatim_with_selfupdate_disabled():
    """13 keys, the bootstrap script's order, ci=true resolved.
    sdkman_selfupdate_feature=false is load-bearing: `sdk selfupdate` pipes
    CANDIDATES_API/selfupdate/<channel>/<platform> into bash and could rewrite
    src/, silently undoing the pinned install."""
    text = _text(INSTALLER)
    written = re.search(r'cat >"\$SDKMAN_DIR/etc/config" <<\'SDKMAN_CONFIG\'\n(.*?)\nSDKMAN_CONFIG\n',
                        text, re.DOTALL)
    assert written, "etc/config is no longer written from a literal block"
    assert written.group(1).splitlines() == list(CONFIG_KEYS)
    assert "sdkman_selfupdate_feature=false" in text


def test_candidates_cache_is_seeded_non_empty_and_without_egress():
    """Decision (ported): the bootstrap script primed this with a bare
    `curl -s`, which leaves an EMPTY file on any transient failure — while
    sdkman-init.sh reads it unconditionally. Seeded instead; existence and
    non-emptiness are mandatory, freshness is not (___sdkman_check_candidates_
    cache refreshes it at first use)."""
    text = _text(INSTALLER)
    assert '"$SDKMAN_DIR/var/candidates"' in text
    # [a-z0-9,] — the class MUST include digits: the real catalog contains
    # `http4k`, and a [a-z,]-only pattern silently fails on it.
    seed = re.search(r"'([a-z0-9,]{200,})' >\"\$SDKMAN_DIR/var/candidates\"", text)
    assert seed, "var/candidates is no longer seeded from a literal snapshot"
    candidates = seed.group(1).split(",")
    assert len(candidates) > 60
    # The snapshot is byte-identical to api.sdkman.io/2/candidates/all.
    assert len(seed.group(1)) == 594
    # The candidates this image family actually installs must be in the list.
    assert {"java", "gradle", "maven", "kotlin"} <= set(candidates)


def test_version_stamps_are_written():
    text = _text(INSTALLER)
    assert re.search(r'printf \'%s\\n\' "\$SDKMAN_CLI_VERSION" >"\$SDKMAN_DIR/var/version"', text)
    # Required even though the native CLI is not installed: selfupdate compares
    # it with `<`, which errors on a missing file.
    assert re.search(r'printf \'%s\\n\' \'0\.7\.34\' >"\$SDKMAN_DIR/var/version_native"', text)


def test_extract_and_flatten_replicate_the_broker_shape():
    """No --strip-components: unpack, delete loose files in the destination
    src/, copy the tree in, drop the unpacked root."""
    text = _code(INSTALLER)
    assert re.search(r'unzip -qo "\$ARCHIVE" -d "\$tmp_dir"', text)
    assert re.search(r'find "\$SDKMAN_DIR/src" -maxdepth 1 -type f -delete', text)
    assert re.search(r'cp -rf "\$tmp_dir"/sdkman-\*/\* "\$SDKMAN_DIR"', text)
    assert re.search(r'rm -rf "\$tmp_dir"/sdkman-\*', text)
    assert re.search(r'unzip\b[^\n]*--strip-components', text) is None


@pytest.mark.parametrize("rel", SYNTHESISED)
def test_every_synthesised_file_is_post_conditioned(rel):
    """The mirror's own failure mode: a zip that unpacks but leaves the
    synthesised state behind. Both the installer and the shipped check gate it."""
    text = _text(INSTALLER)
    assert f"$SDKMAN_DIR/{rel}" in text
    check = json.loads(_text(FEATURE_JSON))["postInstallCheck"]["command"]
    assert f"test -s /home/jovyan/.sdkman/{rel}" in check


def test_deliberately_not_reproduced():
    """Each of these was a broker behaviour the port intentionally drops; if
    one reappears, the reason it was dropped needs re-arguing, not re-adding."""
    text = _code(INSTALLER)
    # rc mutation would fight the generated Dockerfile PATH and profile.d hook.
    for rc in (".bashrc", ".bash_profile", ".zshrc"):
        assert rc not in text, f"{rc} must not be touched from an image build"
    # the native CLI is a SEPARATE per-platform artefact, -f-guarded at every
    # call site with a legacy bash fallback (only `sdk help` polish is lost).
    assert "libexec" not in text
    assert "sdkman-native" not in text


# ---------------------------------------------------------------------------
# (c) cache-key parity (download_direct: $TOOLCACHE_DIR/$tool/$(basename "$url"))
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("arch", ARCHES)
def test_installer_and_stager_build_the_same_url_byte_exact(arch):
    url = _installer_url(INSTALLER)
    assert url == CANONICAL, "installer URL drifted from the canonical release asset"
    assert _tool_url(arch) == url, \
        f"stager tool_url('{TOOL}', pin, {arch}) diverged from the installer URL — the " \
        "mirror key would silently never hit"


@pytest.mark.parametrize("arch", ARCHES)
def test_the_load_bearing_basename_survives(arch):
    """download_direct keys the cache as <tool>/$(basename "$url"); renaming,
    normalising or shortening the asset name would silently miss the mirror."""
    assert _installer_basename(INSTALLER) == BASENAME
    assert _tool_url(arch).endswith("/" + BASENAME)


@pytest.mark.parametrize("arch", ARCHES)
def test_red_proof_baseline_shared_no_cache_key_with_the_stager(tmp_path, arch):
    old = tmp_path / "install_old.sh"
    old.write_text(_git_show("features/java-sdkman/install.sh"), encoding="utf-8")
    assert _installer_basename(old) == ""


def test_red_proof_baseline_stager_had_no_sdkman_cli_arm(tmp_path):
    old = tmp_path / "stage-baseline.sh"
    old.write_text(_git_show("scripts/stage-toolcache.sh"), encoding="utf-8")
    for arch in ARCHES:
        assert _tool_url(arch, script_path=old) == ""
    assert TOOL not in re.search(r'^TOOLS=\((.*)\)$', _git_show("scripts/stage-toolcache.sh"),
                                 re.MULTILINE).group(1)
    assert TOOL in re.search(r'^TOOLS=\((.*)\)$', _text(STAGE_SCRIPT), re.MULTILINE).group(1)


# ---------------------------------------------------------------------------
# (d) digests
# ---------------------------------------------------------------------------

def test_checksums_block_is_complete_and_arch_independent():
    blk = _checksums()[TOOL]
    assert blk["pinned_version"] == _versions()[TOOL] == PIN
    amd = blk["checksums"][PIN]["amd64"]
    arm = blk["checksums"][PIN]["arm64"]
    for digest in (amd, arm):
        assert re.fullmatch(r"[0-9a-f]{64}", digest), digest
    # ONE architecture-independent asset (gradle/tinytex precedent): divergence
    # here means the staging assumption broke.
    assert amd == arm, \
        "sdkman-cli digests diverged per-arch — upstream publishes ONE release zip " \
        "for both arches; investigate before touching this test"
    assert blk["archive_format"] == "zip", "extract=false is only correct for a zip"
    # And the template must agree with the installer and the stager.
    assert blk["archive_url_template"].replace("{version}", PIN) == CANONICAL


def test_red_proof_baseline_checksums_lacked_sdkman_cli():
    with pytest.raises(KeyError):
        _checksums(_git_show("checksums.json"))[TOOL]


# ---------------------------------------------------------------------------
# (e) staging list rows (expected grows with TOOLS — that is the contract)
# ---------------------------------------------------------------------------

def test_list_mode_emits_sdkman_cli_rows_with_matching_digests():
    env = dict(os.environ,
               VERSIONS_FILE=str(REPO / "versions.json"),
               CHECKSUMS_FILE=str(REPO / "checksums.json"))
    r = subprocess.run(
        [_bash(), str(STAGE_SCRIPT), "--mode", "list", "--arch", "amd64,arm64"],
        capture_output=True, text=True, env=env, cwd=str(REPO), check=False)
    assert r.returncode == 0, r.stderr
    rows = [ln for ln in r.stdout.splitlines() if re.search(rf"(^|\t){TOOL}(\t|$)", ln)]
    assert len(rows) == 2, rows
    blk = _checksums()[TOOL]["checksums"][PIN]
    for arch in ARCHES:
        row = next(ln for ln in rows if arch in ln)
        assert blk[arch] in row, row
        assert BASENAME in row, row
    assert "skipping" not in r.stderr, r.stderr
    # One row per tool per arch: registering the tool grew the matrix by 2.
    # Rows are 7-column TSV (tool arch version digest url staged-path
    # mirror-repo); the set is taken over ALL rows, not the sdkman-cli subset.
    all_rows = [ln for ln in r.stdout.splitlines()
                if ln.count("\t") == 6 and not ln.startswith("tool\tarch\tversion\t")]
    tools = {ln.split("\t")[0] for ln in all_rows}
    declared = re.search(r'^TOOLS=\((.*)\)$', _text(STAGE_SCRIPT), re.MULTILINE).group(1).split()
    assert tools == set(declared), (tools ^ set(declared))
    assert len(all_rows) == len(declared) * len(ARCHES)


# ---------------------------------------------------------------------------
# (f) the shipped postInstallCheck got STRONGER, not softer
# ---------------------------------------------------------------------------

def test_post_install_check_anchors_the_synthesised_state():
    check = json.loads(_text(FEATURE_JSON))["postInstallCheck"]
    cmd = check["command"]
    assert "||" not in cmd, "a trailing || turns verification failure into success"
    for forbidden in ("sh -c", "bash -c", "bash -lc"):
        assert forbidden not in cmd
    assert cmd.count("test -s /home/jovyan/.sdkman/") >= 1 + len(SYNTHESISED)
    assert "test -d /home/jovyan/.sdkman/candidates" in cmd
    assert "command -v sdk" in cmd
    assert 'echo "java-sdkman: check OK' in cmd


# ---------------------------------------------------------------------------
# (g) runtime fail-closed (the real installer, minimal sandbox)
# ---------------------------------------------------------------------------

def _run_sandboxed(overrides, tmp_path):
    """Run the real installer with an isolated PATH (no sdk, no download_direct
    helper stack) and no SoT reachable from cwd."""
    env = {
        "PATH": f"{tmp_path}:/usr/bin:/bin",
        "HOME": str(tmp_path / "home"),
        "TMPDIR": str(tmp_path),
        "SDKMAN_DIR": str(tmp_path / "home" / ".sdkman"),
        "NB_USER": "jovyan", "NB_UID": "1001", "NB_GID": "1001",
    }
    env.update(overrides)
    return subprocess.run([_bash(), str(INSTALLER)], env=env, cwd=str(tmp_path),
                          capture_output=True, text=True, check=False)


def test_sandbox_without_version_fails_closed_unresolved(tmp_path):
    """No fh_resolve_version, no SDKMAN_CLI_VERSION: the installer must name
    FH_VERSION_UNRESOLVED and exit 1 — never fall back to an unpinned script."""
    (tmp_path / "home").mkdir(parents=True, exist_ok=True)
    proc = _run_sandboxed({"SDKMAN_CLI_VERSION": ""}, tmp_path)
    assert proc.returncode == 1, proc.stdout + proc.stderr
    assert "FH_VERSION_UNRESOLVED" in proc.stderr


def test_sandbox_without_download_direct_fails_loud_never_pipes(tmp_path):
    """The core anti-regression: with the version pinned but the helper absent,
    the installer must exit 1 naming FH_SDKMAN_INSTALL_FAILED. The pre-fix form
    had no such branch — it reached the network unconditionally instead, which
    is the behaviour this port removes."""
    (tmp_path / "home").mkdir(parents=True, exist_ok=True)
    for name in ("unzip", "zip", "su", "mktemp"):
        src = subprocess.run(["which", name], capture_output=True, text=True, check=False)
        if src.returncode == 0:
            (tmp_path / name).symlink_to(src.stdout.strip())
    proc = _run_sandboxed({"SDKMAN_CLI_VERSION": PIN}, tmp_path)
    assert proc.returncode == 1, proc.stdout + proc.stderr
    assert "FH_SDKMAN_INSTALL_FAILED" in proc.stderr
    assert "download_direct helper not found" in proc.stderr
    assert "java-sdk: SDKMAN installation complete" not in proc.stdout
