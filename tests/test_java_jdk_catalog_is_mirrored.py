"""java-jdk resolves JDK candidates from a VENDORED catalog, not a live call.

Before this change, `features/java-jdk/install.sh` discovered candidates by
shelling out to the SDKMAN CLI's list command, which curls the upstream java
versions-list endpoint on EVERY invocation (the CLI keeps no catalog cache). A
published, digest-pinned image therefore still depended on an unpinned
third-party endpoint, and the JDK a build resolved was a function of what that
endpoint rendered at that moment.

The table is now committed beside the installer, per platform, byte for byte,
and the three discovery pipelines read it with `cat`. The swap is only
behaviour-preserving if the bytes and the filters are BOTH unchanged, so this
file pins all of it:

  (a) vendored  — both platform tables exist, are non-empty, and match the
                  digests in checksums.json (tools.sdkman-java-catalog).
  (b) integrity — the amd64/arm64 digests differ (the tables list different
                  identifiers and name the platform in their header).
  (c) no live call — no `sdk list` invocation survives anywhere under
                  features/, and no SDKMAN host literal appears on an
                  executable line (a host may only appear in prose or in a
                  failure message that performs no fetch).
  (d) parity    — the EXACT filter strings from the installer (extracted from
                  the shipped text, never retyped) resolve, against the
                  vendored bytes, to the same values the live endpoint gave:
                  ALL THREE of numeric majors, 'latest' and 'ea' resolve
                  NOTHING and fall through to the plain default install. Those
                  are the pre-existing upstream-owned quirks (a `cut -f 6` that
                  only ever sees delimiter-free lines, and a grep pattern
                  starting with `-` passed without `--`); this test pins them
                  as OBSERVED behaviour so a future "cleanup" cannot silently
                  change which JDK a profile gets.
  (e) fail-closed — a missing catalog aborts with its own FH_* marker; no
                  retry, no fallback to the network, TOOLCACHE_STRICT unset.

Red proof: the immutable baseline blob (BASELINE_SHA) still contains the live
`sdk list java` call, so (c)/(d) would have failed before the change.
"""

import hashlib
import json
import re
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
FEATURE = REPO / "features" / "java-jdk"
INSTALLER = FEATURE / "install.sh"
CHECKSUMS = REPO / "checksums.json"
TOOL = "sdkman-java-catalog"

# Immutable anchor: the last commit whose java-jdk installer still reached the
# live endpoint. NEVER re-point this at HEAD.
BASELINE_SHA = "7d56d07"

PLATFORMS = {
    "amd64": "linuxx64",
    "arm64": "linuxarm64",
}

# Verified byte sizes of the captured tables (also in checksums.json notes).
SIZES = {"linuxarm64": 7975, "linuxx64": 8344}

_SDKMAN_HOSTS = ("api.sdkman.io", "broker.sdkman.io", "get.sdkman.io")

# The footer line both tables end with. It is present in the vendored bytes,
# but NO shipped filter ever returns it: the 'latest' pattern begins with `-`
# and is passed to grep without a `--` separator, so grep treats `-tem$` as
# option letters and yields nothing. Recorded here because a future reader of
# the table will wonder.
FOOTER_DEFAULT_LINE = "$ sdk install java                 install the default: 25.0.4.1+1-tem"


def _installer_text() -> str:
    return INSTALLER.read_text(encoding="utf-8")


def _installer_code() -> str:
    """Installer text with the `-lc \"…\"` escaping normalised away.

    The shipped lines escape inner quotes and `$` for the `su -lc` wrapper
    (`\"`, `\\$`). Normalising lets the assertions below reference the exact
    filter strings without duplicating that escaping.
    """
    return _installer_text().replace('\\"', '"').replace("\\$", "$")


def _checksum_block() -> dict:
    return json.loads(CHECKSUMS.read_text(encoding="utf-8"))["tools"][TOOL]


def _digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _baseline_installer() -> str:
    proc = subprocess.run(
        ["git", "show", f"{BASELINE_SHA}:features/java-jdk/install.sh"],
        cwd=REPO, capture_output=True, text=True,
    )
    assert proc.returncode == 0, (
        f"red-proof anchor {BASELINE_SHA} is not resolvable in this checkout "
        f"(needs full history): {proc.stderr.strip()}"
    )
    return proc.stdout


def _snapshot(platform_token: str) -> Path:
    return FEATURE / f"sdkman-java-catalog.{platform_token}.txt"


def _run_filter(pipeline: str, env_extra: dict) -> str:
    """Execute a filter string extracted from the shipped installer."""
    proc = subprocess.run(
        ["bash", "-c", pipeline],
        cwd=REPO, capture_output=True, text=True,
        env={"PATH": "/usr/bin:/bin", **env_extra},
    )
    assert proc.returncode == 0, f"filter failed: {pipeline}\n{proc.stderr}"
    return proc.stdout.strip()


# ---------------------------------------------------------------------------
# (a) + (b) the vendored bytes
# ---------------------------------------------------------------------------

class TestVendoredCatalog:
    @pytest.mark.parametrize("arch,token", sorted(PLATFORMS.items()))
    def test_snapshot_present_and_pinned_by_checksums(self, arch, token):
        snap = _snapshot(token)
        assert snap.is_file(), f"missing vendored catalog: {snap}"
        blk = _checksum_block()
        pinned = blk["pinned_version"]
        assert blk["checksums"][pinned][arch] == _digest(snap), (
            f"{snap.name} does not match checksums.json tools.{TOOL}"
            f".checksums[{pinned}][{arch}] — re-vendor or re-pin, never drift"
        )
        assert snap.stat().st_size == SIZES[token]

    def test_platform_digests_differ(self):
        """Per-arch digests are not copy-paste: the tables genuinely differ."""
        digests = {_digest(_snapshot(t)) for t in PLATFORMS.values()}
        assert len(digests) == 2

    @pytest.mark.parametrize("token", sorted(PLATFORMS.values()))
    def test_table_shape_matches_the_endpoints_rendering(self, token):
        """The bytes are the rendered table: header, 4-column rows, and the
        identifier the fallback default installs is really in it."""
        text = _snapshot(token).read_text(encoding="utf-8")
        assert "| Use | Version" in text and "Identifier" in text
        assert "Temurin" in text
        assert re.search(r"\|\s*25\.0\.4\.1\+1\s*\|\s*25\.0\.4\.1\+1-tem", text), (
            "the version the SDKMAN default resolves to must be listed, else "
            "the fallback-to-default behaviour pinned below is meaningless"
        )
        assert f"install the default: 25.0.4.1+1-tem" in text

    def test_no_ansi_or_crlf_in_vendored_bytes(self):
        for token in PLATFORMS.values():
            raw = _snapshot(token).read_bytes()
            assert b"\x1b" not in raw and b"\r" not in raw


# ---------------------------------------------------------------------------
# (c) the live dependency is gone
# ---------------------------------------------------------------------------

class TestNoLiveEndpoint:
    def test_installer_never_names_an_sdkman_host(self):
        text = _installer_text()
        for host in _SDKMAN_HOSTS:
            assert host not in text, f"{host} must not appear in {INSTALLER.name} at all"

    def test_no_sdk_list_invocation_survives_anywhere(self):
        offenders = []
        for path in sorted((REPO / "features").rglob("*")):
            if not path.is_file():
                continue
            try:
                lines = path.read_text(encoding="utf-8").splitlines()
            except UnicodeDecodeError:
                continue
            for no, line in enumerate(lines, 1):
                if "sdk list" in line and not line.lstrip().startswith("#"):
                    offenders.append(f"{path.relative_to(REPO)}:{no}")
        assert offenders == [], f"live catalog calls remain: {offenders}"

    def test_sdkman_hosts_appear_only_in_prose_or_failure_text(self):
        """Every remaining SDKMAN host literal under features/ is inert: a
        comment, or the wording of a failure message that fetches nothing."""
        offenders = []
        for path in sorted((REPO / "features").rglob("*")):
            if not path.is_file():
                continue
            try:
                lines = path.read_text(encoding="utf-8").splitlines()
            except UnicodeDecodeError:
                continue
            for no, line in enumerate(lines, 1):
                if not any(h in line for h in _SDKMAN_HOSTS):
                    continue
                s = line.lstrip()
                inert = s.startswith("#") or "echo" in s
                fetching = re.search(r"\b(curl|wget|sdk list)\b", s)
                if not inert or fetching:
                    offenders.append(f"{path.relative_to(REPO)}:{no}: {s[:80]}")
        assert offenders == [], f"SDKMAN host reachable from an executable line: {offenders}"

    def test_red_proof_baseline_used_the_live_command(self):
        assert "sdk list java" in _baseline_installer()
        assert "SDKMAN_JAVA_CATALOG" not in _baseline_installer()


# ---------------------------------------------------------------------------
# (d) behaviour parity, filter by filter
# ---------------------------------------------------------------------------

# Verbatim from the shipped installer (normalised escaping), so the replay
# below cannot rot away from the code it is supposed to describe.
LATEST_FILTER = (
    r"""cat "${SDKMAN_JAVA_CATALOG}" | tr -d ' ' | cut -f 6 -d '|' | grep "${suffix}$" | head -n1"""
)
NUMERIC_FILTER = (
    r"""cat "${SDKMAN_JAVA_CATALOG}" | tr -d ' ' | cut -f 6 -d '|' | grep "^${ver}\\..*${suffix}" | head -n1"""
)
EA_FILTER = (
    r"""cat "${SDKMAN_JAVA_CATALOG}" | grep -E "${pattern}" | awk '{print $NF}' | head -n1"""
)


class TestFiltersUnchangedAndEquivalent:
    def test_installer_still_carries_the_same_three_filters(self):
        code = _installer_code()
        for name, pipeline in (("latest", LATEST_FILTER), ("numeric", NUMERIC_FILTER), ("ea", EA_FILTER)):
            assert pipeline in code, f"the {name} discovery pipeline was altered — this change must not touch filters"
        assert code.count('cat "${SDKMAN_JAVA_CATALOG}"') == 3

    def test_baseline_used_the_same_filters_on_the_live_command(self):
        """Parity argument: identical filter, identical bytes => identical
        answer. The baseline piped these same filters off `sdk list java`."""
        base = _baseline_installer()
        assert base.count("sdk list java | tr -d ' ' | cut -f 6 -d '|'") == 2
        assert "sdk list java | grep -E" in base

    @pytest.mark.parametrize("token", sorted(PLATFORMS.values()))
    @pytest.mark.parametrize("ver", ["25", "21", "17", "11", "8"])
    def test_numeric_major_resolves_nothing_so_default_install_is_used(self, token, ver):
        """Production's real shape (JDK_VERSION=25 etc.): `cut -f 6` yields
        only delimiter-free lines, so no `^N.*-tem` candidate exists and the
        installer falls through to the plain default install — exactly as it
        did against the live endpoint. Pinned, not fixed."""
        out = _run_filter(NUMERIC_FILTER, {
            "SDKMAN_JAVA_CATALOG": str(_snapshot(token)),
            "ver": ver, "suffix": "-tem",
        })
        assert out == "", f"numeric {ver} resolved {out!r} against {token}; behaviour changed"

    @pytest.mark.parametrize("token", sorted(PLATFORMS.values()))
    def test_latest_resolves_nothing_because_the_pattern_is_not_dash_dash(self, token):
        """`grep "${suffix}$"` receives `-tem$` with no `--` separator, so grep
        parses option letters and returns nothing: 'latest' falls through to
        the default install too. The footer line that WOULD match if the
        filter were corrected is asserted present below, so this pins a filter
        defect, not missing data. Pinned as observed — fixing it here would
        change which JDK profiles get and confound this determinism change."""
        out = _run_filter(LATEST_FILTER, {
            "SDKMAN_JAVA_CATALOG": str(_snapshot(token)),
            "suffix": "-tem",
        })
        assert out == "", (
            f"'latest' resolved {out!r} against {token}; the shipped filter is "
            "no longer the one this change preserved"
        )
        assert FOOTER_DEFAULT_LINE in _snapshot(token).read_text(encoding="utf-8")

    @pytest.mark.parametrize("token", sorted(PLATFORMS.values()))
    def test_ea_resolves_nothing(self, token):
        out = _run_filter(EA_FILTER, {
            "SDKMAN_JAVA_CATALOG": str(_snapshot(token)),
            "pattern": "openjdk.*ea|openjdk.*-ea",
        })
        assert out == ""


# ---------------------------------------------------------------------------
# (e) fail-closed contract + ordering
# ---------------------------------------------------------------------------

class TestFailClosedAndOrdering:
    def test_distinct_marker_for_a_missing_catalog(self):
        code = _installer_code()
        assert "FH_SDKMAN_CATALOG_UNAVAILABLE" in code
        assert "FH_JAVA_JDK_INSTALL_FAILED" in code, "the existing install marker must survive"

    def test_missing_catalog_aborts_rather_than_falling_back_to_network(self):
        code = _installer_code()
        m = re.search(r"FH_SDKMAN_CATALOG_UNAVAILABLE(.*?)\n}", code, re.DOTALL)
        assert m and "exit 1" in code[m.start():m.start() + m.end() - m.start() + 400]

    def test_sdkman_absent_abort_still_precedes_catalog_resolution(self):
        """test_java_sdkman_install_failure_is_loud owns the 'include
        java-sdkman first' early abort; the vendored catalog must not preempt
        it, or that contract changes meaning."""
        text = _installer_text()
        assert text.index("ERROR - SDKMAN not available") < text.index("resolve_catalog")

    def test_resolve_catalog_is_called_from_the_main_shell(self):
        """Inside `$( )` an abort would be swallowed by the subshell and a
        missing catalog would masquerade as 'no candidate'."""
        for line in _installer_text().splitlines():
            if "resolve_catalog" in line and not line.lstrip().startswith("#"):
                assert "$(" not in line.split("resolve_catalog")[0], line

    def test_no_retry_no_strict_toolcache_coupling(self):
        code = _installer_code()
        assert "TOOLCACHE_STRICT" not in code
        # Executable lines only: the catalog block's own prose says 'no retry'.
        body = "\n".join(
            l for l in code.splitlines() if not l.lstrip().startswith("#")
        )
        for token in ("for attempt", "backoff", "sleep ", "retry"):
            assert token not in body, f"{token!r}: a missing catalog is fatal, not retried"

    def test_checksums_entry_documents_the_endpoint_it_replaced(self):
        blk = _checksum_block()
        assert blk["pinned_version"] in blk["checksums"]
        assert "{platform}" in blk["archive_url_template"]
        assert blk["archive_format"] == "text"
        assert set(blk["checksums"][blk["pinned_version"]]) == set(PLATFORMS)
