#!/usr/bin/env bash
# Auto-inserted by scripts/inject_prebaked_helpers.sh
# Source shared feature helpers (prebaked into image) or fall back to repository helper
if [ -n "${FEATURE_HELPERS_DIR:-}" ] && [ -f "${FEATURE_HELPERS_DIR}/helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "${FEATURE_HELPERS_DIR}/helpers.sh"
elif [ -f "../../../scripts/lib/features.sh" ]; then
  # shellcheck disable=SC1091
  source "../../../scripts/lib/features.sh"
fi
set -euo pipefail

# java-jdk install - JDK installation via SDKMAN
JDK_VERSION=${JDK_VERSION:-25}
SDKMAN_JAVA_IDENTIFIER=${SDKMAN_JAVA_IDENTIFIER:-temurin}
JAVA_JDK_ALLOW_SDKMAN_FALLBACK=${JAVA_JDK_ALLOW_SDKMAN_FALLBACK:-false}

echo "java-jdk: installing JDK version=${JDK_VERSION} distribution=${SDKMAN_JAVA_IDENTIFIER}"

# Verify SDKMAN is available
if ! command -v sdk >/dev/null 2>&1; then
  # Try to source SDKMAN init
  if [ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]; then
    set +u
    # shellcheck source=/dev/null
    source "$HOME/.sdkman/bin/sdkman-init.sh"
    set -u
  else
    echo "java-jdk: ERROR - SDKMAN not available. Please include java-sdkman feature first." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Vendored SDKMAN Java version catalog (candidate discovery input).
#
# Discovery used to shell out to the SDKMAN java versions-list command, which
# performed a LIVE `curl` of the upstream catalog endpoint (its URL is
# recorded in checksums.json under tools.sdkman-java-catalog) on
# every single invocation: the CLI's list path curls it unconditionally and
# keeps no catalog cache, so seeding one was not an option. That left the
# publish path dependent on an unpinned third-party endpoint, and made the JDK
# resolved by a build a function of what that endpoint happened to render at
# that moment.
#
# The rendered table is now vendored per platform, byte for byte, next to this
# script as sdkman-java-catalog.<platform>.txt, captured with the same empty
# `current=&installed=` query parameters a build-time caller sends (nothing is
# installed yet, so the Use column is empty in the vendored bytes exactly as
# it is during a build). Byte-identity is what makes this swap behaviour
# preserving rather than behaviour changing: the real `sdk list java`, run in a
# non-tty pipe, emits exactly these bytes (7975 for linuxarm64, 8344 for
# linuxx64), so every filter below is fed the same input it was fed before and
# therefore returns the same answer — INCLUDING the pre-existing quirks. One of
# them has since been fixed: the discovery filters used `cut -f 6`, but a real
# table row carries only four pipe fields (vendor, Use, Version, Identifier),
# so field 6 was always empty, numeric majors resolved no candidate and every
# pinned build silently fell through to SDKMAN's default install. The filters
# now read `cut -f 4` — the Identifier column — so a pinned numeric major
# resolves the real identifier of that major. The remaining quirks stay pinned
# as OBSERVED behaviour by tests/test_java_jdk_catalog_is_mirrored.py: `latest`
# passes an option-looking pattern (`-tem$`) to grep with no `--` separator and
# resolves nothing, and the EA pattern matches no row of the vendored bytes. A
# numeric selection that STILL finds no candidate falls through to the default
# install, and the post-install major gate below aborts the build rather than
# letting the default masquerade as the pinned major.
#
# Integrity of the vendored bytes is pinned in checksums.json
# (tools.sdkman-java-catalog) and asserted there by that test with hashlib.
# It is NOT re-hashed here on purpose: this installer runs under the
# closed-PATH sandbox of tests/, which stages no sha256 tool, and git already
# authenticates the blob it checks out. No retry, no fallback to the live
# endpoint — a missing catalog is a hard failure.
# ---------------------------------------------------------------------------
# Resolved with shell expansion and builtins only — deliberately NOT the
# `$(cd "$(dirname …)")` idiom other installers use, because this script runs
# under the closed-PATH sandbox of tests/test_java_sdkman_install_failure_is_loud.py,
# which stages no `dirname`. `cd`/`pwd` are builtins, so discovery needs no
# external command beyond `cat`.
_self="${BASH_SOURCE[0]:-$0}"
case "$_self" in
  */*) SCRIPT_DIR="$(cd "${_self%/*}" && pwd)" ;;
  *) SCRIPT_DIR="." ;;
esac
unset _self

SDKMAN_JAVA_CATALOG=""

# Resolve the vendored catalog for the build machine's platform. Called only
# by the branches that actually need discovery ('ea', 'latest', numeric major);
# 'default' and an explicit identifier never touch it. MUST be called from the
# main shell, never inside a command substitution, so its abort cannot be
# swallowed by a subshell.
resolve_catalog() {
  if [ -n "$SDKMAN_JAVA_CATALOG" ]; then
    return 0
  fi
  local platform name candidate
  # Prefer the platform SDKMAN itself recorded (java-sdkman's var/platform),
  # else reproduce its infer_platform() mapping — lowercase tokens, because
  # the API rejects LINUX64. Builds are native per arch (no QEMU), so
  # build-time uname == the arch the catalog was rendered for.
  platform=""
  if [ -s "$HOME/.sdkman/var/platform" ]; then
    platform="$(tr -d '[:space:]' <"$HOME/.sdkman/var/platform")"
  fi
  if [ -z "$platform" ]; then
    case "$(uname -m)" in
      x86_64 | amd64) platform="linuxx64" ;;
      aarch64 | arm64) platform="linuxarm64" ;;
      *) platform="unknown" ;;
    esac
  fi
  name="sdkman-java-catalog.${platform}.txt"
  # SCRIPT_DIR is the feature dir in every real context: the bind mount
  # /tmp/features/<feat> (dockerfile_template.j2:158, readonly) during a
  # build, and the repository checkout under tests/.
  for candidate in \
    "${SCRIPT_DIR}/${name}" \
    "/tmp/features/java-jdk/${name}" \
    "${PWD}/features/java-jdk/${name}"; do
    if [ -s "$candidate" ]; then
      SDKMAN_JAVA_CATALOG="$candidate"
      echo "java-jdk: using vendored SDKMAN java catalog for ${platform}: ${candidate}"
      return 0
    fi
  done
  echo "❌ java-jdk: FH_SDKMAN_CATALOG_UNAVAILABLE — no vendored SDKMAN java catalog '${name}' for platform ${platform} (looked in ${SCRIPT_DIR}, /tmp/features/java-jdk and ${PWD}/features/java-jdk). Candidate discovery for JDK_VERSION='${JDK_VERSION}' cannot run without it. Re-vendor the table and pin it in checksums.json (tools.sdkman-java-catalog) rather than reaching for the live catalog endpoint again; aborting rather than resolving a JDK against no catalog." >&2
  exit 1
}

# Helper: query the vendored catalog for a matching candidate (run as NB_USER).
# Candidate DISCOVERY is allowed to come back empty (each caller has a
# documented fallback below), but a missing candidate never becomes a green
# build: the install that follows is verified and fatal on failure.
query_candidate() {
  local pattern="$1"
  su - ${NB_USER:-jovyan} -s /bin/bash -lc \
    "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; cat \"${SDKMAN_JAVA_CATALOG}\" | grep -E \"${pattern}\" | awk '{print \$NF}' | head -n1" || true
}

# Run one `sdk install java …` as the target user, failing loudly.
#
# `sdk install java` is a build-time network fetch (SDK CDN + the vendor's
# archive). It used to end in `|| true`, so when the fetch failed the
# installer printed the upstream refusal and kept going: CI run 39053927880
# (arm64) shipped
#   "Download has failed, aborting!" / "Can not install java <ver> at this
#    time..."  →  "java-jdk: WARNING - java command not available"  →  done,
# and the leg still went green. Fail at the point of failure, naming the
# producer (java-sdkman supplies `sdk`) so the blame cannot drift.
run_sdk_install() {
  local sdk_cmd="$1"
  if ! su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; ${sdk_cmd}"; then
    echo "❌ java-jdk: FH_JAVA_JDK_INSTALL_FAILED — '${sdk_cmd}' failed for user ${NB_USER:-jovyan}. This stage performs a build-time network fetch through the SDKMAN installed by the java-sdkman feature; aborting rather than publishing an image with no JDK in it." >&2
    exit 1
  fi
}

# Install JDK based on version specification
install_jdk() {
  local ver="$1"
  local dist_id="$2"
  local cand

  # Case 1: 'default' - let SDKMAN pick
  if [ -z "${ver}" ] || [ "${ver}" = "default" ]; then
    echo "java-jdk: installing default java via sdk"
    run_sdk_install "sdk install java"
    return 0
  fi

  # Case 2: 'ea' - latest Early Access
  if [ "${ver}" = "ea" ]; then
    echo "java-jdk: selecting latest openjdk EA via SDKMAN"
    resolve_catalog
    cand=$(query_candidate "openjdk.*ea|openjdk.*-ea") || true
    if [ -n "${cand}" ]; then
      run_sdk_install "sdk install java ${cand}"
    else
      echo "java-jdk: no openjdk EA candidate found; falling back to default"
      run_sdk_install "sdk install java"
    fi
    return 0
  fi

  # Case 3: 'latest' - latest stable from specified distribution
  if [ "${ver}" = "latest" ]; then
    echo "java-jdk: selecting latest ${dist_id} candidate via SDKMAN"
    # Look for candidates ending with distribution suffix (e.g., -tem for temurin)
    local suffix=""
    case "${dist_id}" in
      temurin) suffix="-tem" ;;
      openjdk) suffix=".*" ;;
      oracle) suffix="-oracle" ;;
      *) suffix=".*" ;;
    esac

    resolve_catalog
    cand=$(su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; cat \"${SDKMAN_JAVA_CATALOG}\" | tr -d ' ' | cut -f 4 -d '|' | grep \"${suffix}\$\" | head -n1") || true

    if [ -n "${cand}" ]; then
      run_sdk_install "sdk install java ${cand}"
    else
      echo "java-jdk: no ${dist_id} candidate found; falling back to default"
      run_sdk_install "sdk install java"
    fi
    return 0
  fi

  # Case 4: Numeric major version (8, 11, 17, 21, 25, etc.)
  if echo "${ver}" | grep -Eq '^[0-9]+$'; then
    echo "java-jdk: selecting ${dist_id} version ${ver} via SDKMAN"
    local suffix=""
    case "${dist_id}" in
      temurin) suffix="-tem" ;;
      openjdk) suffix=".*" ;;
      oracle) suffix="-oracle" ;;
      *) suffix=".*" ;;
    esac

    resolve_catalog
    cand=$(su - ${NB_USER:-jovyan} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; cat \"${SDKMAN_JAVA_CATALOG}\" | tr -d ' ' | cut -f 4 -d '|' | grep \"^${ver}\\..*${suffix}\" | head -n1") || true

    if [ -n "${cand}" ]; then
      run_sdk_install "sdk install java ${cand}"
    else
      echo "java-jdk: no matching ${dist_id} candidate for version ${ver}; trying default"
      run_sdk_install "sdk install java"
    fi
    return 0
  fi

  # Case 5: Specific identifier (e.g., "17.0.9-tem")
  echo "java-jdk: installing specific identifier: ${ver}"
  run_sdk_install "sdk install java ${ver}"
}

# ---------------------------------------------------------------------------
# Routing. The pinned pair — temurin at exactly the SoT version (JDK_VERSION
# ∈ {25, 25.0.4.1+1, 25.0.4.1+1-tem}, i.e. whatever tools.jdk resolves to) —
# installs from the offline Harbor toolcache mirror through download_direct,
# digest-verified, producing the EXACT on-disk layout an SDKMAN candidate
# install would (candidate dir <VERSION>-tem + `current` symlink). Every other
# request (8, 21, latest, ea, or any non-temurin identifier) keeps the legacy
# `sdk install java` path above, unchanged. An explicit
# JAVA_JDK_ALLOW_SDKMAN_FALLBACK=true forces the legacy path even for the
# pinned pair; the default is fail-closed on the pinned path — there is NO
# silent SDKMAN fallback.
# ---------------------------------------------------------------------------

# Resolve the version from the SoT (versions/versions.yaml -> versions.json),
# fail closed. jdk is checksum-pinned (checksums.json tools.jdk.checksums) and
# mirrored by scripts/stage-toolcache.sh; it must never fall back to an SDKMAN
# "latest" candidate or a bare curl (java-gradle precedent).
resolve_version(){
  local tool="$1" v=""
  if command -v fh_resolve_version >/dev/null 2>&1; then
    v=$(fh_resolve_version "$tool" || true)
    if [ -n "$v" ]; then
      echo "$v"; return 0
    fi
  fi
  if [ -f "${PWD}/artefacts/versions.json" ]; then
    v=$(jq -r --arg t "$tool" '.tools[$t] // empty' "${PWD}/artefacts/versions.json" 2>/dev/null || true)
  elif [ -f /tmp/versions.json ]; then
    v=$(jq -r --arg t "$tool" '.tools[$t] // empty' /tmp/versions.json 2>/dev/null || true)
  fi
  echo "$v"
}

VERSION=$(resolve_version "jdk")
if [ -z "${VERSION}" ]; then
  echo "❌ java-jdk: FH_VERSION_UNRESOLVED — pinned version for 'jdk' not found via fh_resolve_version/artefacts/versions.json; the pinned pair cannot be resolved against no SoT and must not drift to an SDKMAN 'latest' candidate." >&2
  exit 1
fi

# True (0) iff the request IS the pinned pair: temurin at exactly the SoT
# version, spelled as the bare major (25), the full version (25.0.4.1+1), or
# the SDKMAN identifier (25.0.4.1+1-tem). 'latest'/'ea' name no major and
# never pin; any other major, full version, or identifier is a legacy request.
jdk_request_is_pinned() {
  [ "${SDKMAN_JAVA_IDENTIFIER}" = "temurin" ] || return 1
  case "${JDK_VERSION}" in
    latest | ea) return 1 ;;
  esac
  case "${JDK_VERSION}" in
    *-tem) [ "${JDK_VERSION%-tem}" = "${VERSION}" ] ;;
    *[!0-9]*) [ "${JDK_VERSION}" = "${VERSION}" ] ;;
    *) [ "${JDK_VERSION}" = "${VERSION%%.*}" ] ;;
  esac
}

if jdk_request_is_pinned && [ "${JAVA_JDK_ALLOW_SDKMAN_FALLBACK}" != "true" ]; then
  # --- Mirror transport (modelled on java-gradle/install.sh) ---------------
  echo "java-jdk: pinned request — installing ${VERSION} via the offline toolcache mirror"
  NB_USER=${NB_USER:-jovyan}
  NB_UID=${NB_UID:-1001}
  NB_GID=${NB_GID:-1001}
  HOME_DIR="${HOME_DIR:-/home/${NB_USER}}"

  # Target layout — deliberately the SDKMAN candidate layout: the image
  # resolves java from /home/jovyan/.sdkman/candidates/java/current/bin
  # (dockerfile_template.j2 PATH line and /etc/profile.d/solen.sh), and the
  # probes below evaluate that exact artefact. The archive is unpacked to
  # candidates/java/<VERSION>-tem/ with a `current` symlink — byte-for-byte
  # the on-disk shape an `sdk install java <VERSION>-tem` produced — so no
  # consumer, PATH entry, or probe moves.
  JDK_CANDIDATE_DIR="${HOME_DIR}/.sdkman/candidates/java"

  # download_direct performs the toolcache-hit fetch, the publisher-digest
  # verification against checksums.json (tools.jdk.checksums[<VERSION>][<arch>])
  # and the /opt/toolcache seed, failing closed on missing/mismatch and
  # falling back to the origin on cache miss. Its absence is fatal — the
  # pinned pair must not drift to the SDKMAN CDN (the java-gradle precedent,
  # and the very egress this mirror removes). This check MUST precede the
  # tar check: a missing helper is a routing failure, not a packaging one.
  if ! command -v download_direct >/dev/null 2>&1; then
    echo "❌ java-jdk: FH_JAVA_JDK_INSTALL_FAILED — download_direct helper not found (features/_lib/download-release must run first); refusing to fall back to an SDKMAN network install for the pinned ${JDK_VERSION}/${SDKMAN_JAVA_IDENTIFIER} request." >&2
    exit 1
  fi

  # The payload is a tar.gz carrying the full JDK tree, so the feature owns
  # the extract (download_direct's extract branch is single-binary; EXTRACT=
  # false stages the archive at ${SCRATCH_DIR}/jdk). Keep the precondition
  # explicit rather than hoping the base image ships it (java-gradle shape).
  if ! command -v tar >/dev/null 2>&1; then
    apt_install tar || true
  fi
  if ! command -v tar >/dev/null 2>&1; then
    echo "❌ java-jdk: FH_JAVA_JDK_INSTALL_FAILED — tar is not available, so the digest-verified JDK archive cannot be extracted to ${JDK_CANDIDATE_DIR}; refusing to publish an image that advertises java and ships none." >&2
    exit 1
  fi

  ARCH=$(dpkg --print-architecture)
  case "${ARCH}" in
    amd64) RELEASE_ARCH="x64" ;;
    arm64) RELEASE_ARCH="aarch64" ;;
    *) echo "❌ java-jdk: FH_JAVA_JDK_INSTALL_FAILED — Unsupported architecture '${ARCH}'; the Temurin mirror is staged for amd64/arm64 only." >&2; exit 1 ;;
  esac

  # adoptium per-major release repo: '+' is %-encoded in the release tag and
  # '_'-substituted in the asset file name. This URL must stay in lock-step
  # with the jdk arm of tool_url() in scripts/stage-toolcache.sh, which keys
  # the toolcache as $TOOLCACHE_DIR/jdk/$(basename "$url").
  DOWNLOAD_URL="https://github.com/adoptium/temurin25-binaries/releases/download/jdk-${VERSION//+/%2B}/OpenJDK${VERSION%%.*}U-jdk_${RELEASE_ARCH}_linux_hotspot_${VERSION//+/_}.tar.gz"

  # extract=false (5th arg): download_direct fetches + digest-verifies the
  # archive and hands it over as ${SCRATCH_DIR}/jdk; the tree layout below is
  # this feature's responsibility, mirroring what the SDKMAN installer did
  # with the same upstream archive.
  SCRATCH_DIR="/tmp/java-jdk-mirror"
  jdk_fetch_rc=0
  download_direct "$DOWNLOAD_URL" "jdk" "${VERSION}" "${SCRATCH_DIR}" false || jdk_fetch_rc=$?
  if [ "$jdk_fetch_rc" -ne 0 ]; then
    echo "❌ java-jdk: FH_JAVA_JDK_INSTALL_FAILED — download_direct of the pinned archive (${DOWNLOAD_URL}) exited ${jdk_fetch_rc}; the JDK was NOT fetched. The archive is digest-verified against checksums.json tools.jdk and served from the toolcache mirror when staged." >&2
    exit 1
  fi

  if ! mkdir -p "${JDK_CANDIDATE_DIR}"; then
    echo "❌ java-jdk: FH_JAVA_JDK_INSTALL_FAILED — could not create ${JDK_CANDIDATE_DIR}." >&2
    exit 1
  fi
  if ! tar -xzf "${SCRATCH_DIR}/jdk" -C "${SCRATCH_DIR}"; then
    echo "❌ java-jdk: FH_JAVA_JDK_INSTALL_FAILED — tar of the digest-verified archive into ${SCRATCH_DIR} exited non-zero; the jdk-${VERSION} tree was not materialised." >&2
    rm -rf "${SCRATCH_DIR}" || true
    exit 1
  fi
  if ! mv "${SCRATCH_DIR}/jdk-${VERSION}" "${JDK_CANDIDATE_DIR}/${VERSION}-tem"; then
    echo "❌ java-jdk: FH_JAVA_JDK_INSTALL_FAILED — could not place the extracted tree at ${JDK_CANDIDATE_DIR}/${VERSION}-tem." >&2
    rm -rf "${SCRATCH_DIR}" || true
    exit 1
  fi
  rm -rf "${SCRATCH_DIR}" || true

  # SDKMAN candidate layout: current -> <VERSION>-tem (relative symlink, as
  # the SDKMAN installer wrote it — survives a home-dir path being what it is).
  ln -sfn "${VERSION}-tem" "${JDK_CANDIDATE_DIR}/current"

  # Ownership: the flow above ran as root; the sdk-era install ran su'd as
  # ${NB_USER}. Hand the candidate tree back so java behaves exactly as
  # before (jovyan-owned candidate tree, writable caches). Failure is fatal —
  # a root-owned distribution breaks the user contract downstream.
  if ! chown -R "${NB_UID}:${NB_GID}" "${JDK_CANDIDATE_DIR}"; then
    echo "❌ java-jdk: FH_JAVA_JDK_INSTALL_FAILED — could not chown ${JDK_CANDIDATE_DIR} to ${NB_UID}:${NB_GID} (${NB_USER}); the java candidate tree would not be user-owned as every consumer expects." >&2
    exit 1
  fi
else
  install_jdk "${JDK_VERSION}" "${SDKMAN_JAVA_IDENTIFIER}"
fi

# Verify installation. This is the post-condition for every branch above: a
# JDK the target user cannot execute is a failed feature, not a warning —
# `provides: [java, javac]` is a promise the published image has to keep.
#
# `java` is reachable only through $HOME/.sdkman/candidates/java/current/bin,
# which sdkman-init.sh exports. A bare login shell does NOT have it at this
# stage of the build: /etc/profile.d/solen.sh, the hook that would export the
# SDKMAN paths, is written by the RUN that comes AFTER the feature loop
# (solen-cli/solen/generators/dockerfile_template.j2:240-243), and `su -`
# resets PATH through /etc/profile. So a probe that only runs `command -v`
# in a login shell can never pass, even on a healthy install. Evaluate the
# post-condition the way the consumers evaluate it at runtime: source the
# init script, then verify the artefact and its resolvability, with distinct
# exit statuses per broken guarantee.
jdk_probe_rc=0
su - ${NB_USER:-jovyan} -s /bin/bash -lc 'set +u; [ -s "$HOME/.sdkman/bin/sdkman-init.sh" ] || exit 3; source "$HOME/.sdkman/bin/sdkman-init.sh" >/dev/null 2>&1 || exit 4; [ -x "$HOME/.sdkman/candidates/java/current/bin/java" ] || exit 6; command -v java >/dev/null 2>&1 || exit 5' || jdk_probe_rc=$?
if [ "$jdk_probe_rc" -ne 0 ]; then
  case "$jdk_probe_rc" in
    3) cause="no init artefact at \$HOME/.sdkman/bin/sdkman-init.sh for ${NB_USER:-jovyan}" ;;
    4) cause="sdkman-init.sh could not be sourced by ${NB_USER:-jovyan}" ;;
    6) cause="the artefact \$HOME/.sdkman/candidates/java/current/bin/java is missing for ${NB_USER:-jovyan}" ;;
    5) cause="'java' is not resolvable for ${NB_USER:-jovyan} even after sourcing sdkman-init.sh" ;;
    *) cause="the java probe for ${NB_USER:-jovyan} could not be executed (exit ${jdk_probe_rc})" ;;
  esac
  echo "❌ java-jdk: FH_JAVA_JDK_NOT_AVAILABLE — ${cause} although the 'sdk install java' stage exited 0 (distribution ${SDKMAN_JAVA_IDENTIFIER}, version request ${JDK_VERSION}). Aborting rather than publishing an image that advertises java/javac and ships neither." >&2
  exit 1
fi

# Post-install gate: the installed JDK must be the MAJOR the request named.
# Selection is best-effort by design — a candidate the vendored catalog does
# not list falls through to SDKMAN's default — but a pinned profile must not
# ship the default silently: JDK_VERSION=8 that ends up as the default 25 is a
# broken promise, and the install stage exiting 0 proves nothing about WHICH
# java was installed. `java -version` is the only ground truth left. Requests
# that name no major ('default', 'latest', 'ea') are exempt: there is nothing
# to compare against.
expected_major=""
req_ver="${JDK_VERSION%%-*}"
case "${req_ver}" in
  '' | latest | ea | default) ;;
  *)
    expected_major="${req_ver%%.*}"
    case "${req_ver}" in
      1.*) expected_major="${req_ver#1.}"; expected_major="${expected_major%%.*}" ;;
    esac
    ;;
esac

installed_version_line=""
installed_version_rc=0
installed_version_line=$(su - ${NB_USER:-jovyan} -s /bin/bash -lc 'set +u; [ -s "$HOME/.sdkman/bin/sdkman-init.sh" ] || exit 3; source "$HOME/.sdkman/bin/sdkman-init.sh" >/dev/null 2>&1 || exit 4; java -version 2>&1 | head -n1') || installed_version_rc=$?
if [ "$installed_version_rc" -ne 0 ]; then
  echo "❌ java-jdk: FH_JAVA_JDK_MAJOR_MISMATCH — 'java -version' could not be run as ${NB_USER:-jovyan} to verify the installed major for JDK_VERSION='${JDK_VERSION}' (exit ${installed_version_rc}); aborting." >&2
  exit 1
fi
installed_ver="${installed_version_line#*\"}"
installed_ver="${installed_ver%%\"*}"
installed_major="${installed_ver%%.*}"
case "${installed_ver}" in
  1.*) installed_major="${installed_ver#1.}"; installed_major="${installed_major%%.*}" ;;
esac

if [ -n "${expected_major}" ] && [ "${installed_major}" != "${expected_major}" ]; then
  echo "❌ java-jdk: FH_JAVA_JDK_MAJOR_MISMATCH — JDK_VERSION='${JDK_VERSION}' asked for major ${expected_major} but the installed JDK reports '${installed_ver}' (major ${installed_major}). The selection fell through to SDKMAN's default instead of the pinned major; aborting rather than publishing an image with the wrong JDK." >&2
  exit 1
fi
echo "java-jdk: installation successful"
su - ${NB_USER:-jovyan} -s /bin/bash -lc 'java -version' || true

echo "java-jdk: done"
