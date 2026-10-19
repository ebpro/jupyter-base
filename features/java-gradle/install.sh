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

# Resolve the version from the SoT (versions/versions.yaml -> versions.json),
# fail closed. gradle is checksum-pinned (checksums.json tools.gradle) and
# mirrored by scripts/stage-toolcache.sh; it must never fall back to an SDKMAN
# "latest" candidate or a bare curl (hadolint/ctop/dive/starship precedent).
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

# java-gradle install - Gradle build tool (pinned, digest-verified, mirrored)
GRADLE_VERSION=${GRADLE_VERSION:-}

echo "java-gradle: installing Gradle${GRADLE_VERSION:+ version ${GRADLE_VERSION}}"

# Check if Gradle already installed
if command -v gradle >/dev/null 2>&1; then
  echo "java-gradle: Gradle already installed"
  gradle --version || true
  exit 0
fi

NB_USER=${NB_USER:-jovyan}
NB_UID=${NB_UID:-1001}
NB_GID=${NB_GID:-1001}
HOME_DIR="${HOME_DIR:-/home/${NB_USER}}"

# Target layout — deliberately the SDKMAN candidate layout, UNCHANGED from the
# candidate install this replaced: the generated image resolves gradle from
# /home/jovyan/.sdkman/candidates/gradle/current/bin (Dockerfile ENV PATH,
# solen-cli/solen/generators/dockerfile_template.j2:99-105, and the
# /etc/profile.d/solen.sh line at :239), and feature.json's postInstallCheck
# runs `gradle --version` in that runtime environment. The distribution is
# unzipped to candidates/gradle/gradle-<VERSION>/ with a `current` symlink —
# byte-for-byte the on-disk shape the SDKMAN candidate install produced — so no
# consumer, PATH entry or the postInstallCheck moves. SDKMAN itself stays
# installed and functional for java (java-sdkman owns the bootstrap; this
# feature is no longer a consumer of it).
GRADLE_CANDIDATE_DIR="${HOME_DIR}/.sdkman/candidates/gradle"

VERSION="${GRADLE_VERSION}"
if [ -z "$VERSION" ]; then
  VERSION=$(resolve_version "gradle")
fi
if [ -z "$VERSION" ]; then
  echo "❌ java-gradle: FH_VERSION_UNRESOLVED — pinned version for 'gradle' not found via GRADLE_VERSION/fh_resolve_version/artefacts; refusing to fall back to an SDKMAN 'latest' candidate (checksum-pinned tool)" >&2
  exit 1
fi

# download_direct performs the toolcache-hit fetch, the publisher-digest
# verification against checksums.json and the /opt/toolcache seed. Its absence
# is fatal — the same routing the sdk path relied on the java-sdkman feature
# for, now owned by _lib/download-release (declared first in the feature order).
if ! command -v download_direct >/dev/null 2>&1; then
  echo "❌ java-gradle: FH_JAVA_GRADLE_INSTALL_FAILED — download_direct helper not found (features/_lib/download-release must run first); refusing to fall back to an SDKMAN network install. This stage exists to dodge exactly the transient CDN egress (run 39129344307: the SDKMAN candidate fetch died 3× on curl (35) mid-transfer of gradle-${VERSION}.bin on build-amd64-heavy) that the digest-pinned Harbor mirror removes." >&2
  exit 1
fi

# The payload is a zip carrying a full distribution tree, so the feature owns
# the unzip (download_direct's extract branch is tar-only and single-binary —
# see the 5th-arg note below). Keep the precondition explicit rather than
# hoping the base image ships it (java-kernel guard shape).
if ! command -v unzip >/dev/null 2>&1; then
  apt_install unzip || true
fi
if ! command -v unzip >/dev/null 2>&1; then
  echo "❌ java-gradle: FH_JAVA_GRADLE_INSTALL_FAILED — unzip is not available, so the pinned -bin.zip payload cannot be extracted to ${GRADLE_CANDIDATE_DIR}; refusing to publish an image that advertises gradle and ships none." >&2
  exit 1
fi

# services.gradle.org is the publisher's canonical distributions endpoint
# (it 307s to the gradle/gradle-distributions GitHub release backing store;
# the -bin.zip asset is architecture-independent — the SAME asset and digest
# for amd64 and arm64, tinytex precedent). download_direct keys the toolcache
# as $TOOLCACHE_DIR/gradle/$(basename "$url"), so this URL must stay in lock-
# step with the gradle arm of tool_url() in scripts/stage-toolcache.sh.
DOWNLOAD_URL="https://services.gradle.org/distributions/gradle-${VERSION}-bin.zip"

# extract=false (5th arg): download_direct fetches + digest-verifies the zip
# and hands it over as ${SCRATCH_DIR}/gradle; the tree layout below is this
# feature's responsibility, mirroring what the SDKMAN installer did with the
# same upstream archive.
SCRATCH_DIR="/tmp/java-gradle-mirror"
gradle_fetch_rc=0
download_direct "$DOWNLOAD_URL" "gradle" "$VERSION" "$SCRATCH_DIR" false || gradle_fetch_rc=$?
if [ "$gradle_fetch_rc" -ne 0 ]; then
  echo "❌ java-gradle: FH_JAVA_GRADLE_INSTALL_FAILED — download_direct of the pinned archive (${DOWNLOAD_URL}) exited ${gradle_fetch_rc}; gradle was NOT fetched. The archive is digest-verified against checksums.json tools.gradle and served from the toolcache mirror when staged." >&2
  exit 1
fi

if ! unzip -oq "${SCRATCH_DIR}/gradle" -d "${GRADLE_CANDIDATE_DIR}"; then
  echo "❌ java-gradle: FH_JAVA_GRADLE_INSTALL_FAILED — unzip of the digest-verified archive into ${GRADLE_CANDIDATE_DIR} exited non-zero; the gradle-${VERSION} distribution tree was not materialised." >&2
  rm -rf "${SCRATCH_DIR}" || true
  exit 1
fi
rm -rf "${SCRATCH_DIR}" || true

# SDKMAN candidate layout: current -> gradle-<VERSION> (relative symlink, as
# the SDKMAN installer wrote it — survives a home-dir path being what it is).
ln -sfn "gradle-${VERSION}" "${GRADLE_CANDIDATE_DIR}/current"

# Ownership: the whole flow above ran as root; the sdk-era install ran
# su'd as ${NB_USER}. Hand the candidate tree back so gradle behaves exactly
# as before (jovyan-owned caches, ~/.gradle writable). Failure is fatal —
# a root-owned distribution breaks the user contract downstream.
if ! chown -R "${NB_UID}:${NB_GID}" "${GRADLE_CANDIDATE_DIR}"; then
  echo "❌ java-gradle: FH_JAVA_GRADLE_INSTALL_FAILED — could not chown ${GRADLE_CANDIDATE_DIR} to ${NB_UID}:${NB_GID} (${NB_USER}); the gradle candidate tree would not be user-owned as every consumer expects." >&2
  exit 1
fi

# Verify installation: the post-condition for the install above.
#
# The artefact the image resolves at runtime (PATH line above) is
# $HOME/.sdkman/candidates/gradle/current/bin/gradle — probe it DIRECTLY at
# the producer. The old probe sourced sdkman-init.sh first because the sdk
# installer only guaranteed resolvability through the init exports; the
# mirrored install materialises that exact path, so the artefact check is
# both stronger and independent of SDKMAN state (8da2bd8 lesson: never
# evaluate the post-condition in an environment the build does not have).
if [ ! -x "${GRADLE_CANDIDATE_DIR}/current/bin/gradle" ]; then
  echo "❌ java-gradle: FH_JAVA_GRADLE_NOT_AVAILABLE — the artefact ${GRADLE_CANDIDATE_DIR}/current/bin/gradle is missing or not executable for ${NB_USER} although the pinned archive was fetched and extracted. Aborting rather than publishing an image that advertises gradle and ships none." >&2
  exit 1
fi
echo "java-gradle: installation successful"
su - ${NB_USER} -s /bin/bash -lc 'gradle --version' || true

echo "java-gradle: done"
