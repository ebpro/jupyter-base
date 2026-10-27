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

# Run installation
install_jdk "${JDK_VERSION}" "${SDKMAN_JAVA_IDENTIFIER}"

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
