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

echo "java-sdk: installing SDKMAN"

if command -v sdk >/dev/null 2>&1; then
  echo "java-sdk: sdk already available"
  exit 0
fi

SDKMAN_DIR="${SDKMAN_DIR:-$HOME/.sdkman}"
export SDKMAN_DIR

echo "-> java-sdk: installing SDKMAN to $SDKMAN_DIR"

# Ensure per-user dirs exist and are owned correctly
if command -v fh_ensure_user_dirs >/dev/null 2>&1; then
  fh_ensure_user_dirs "${NB_USER:-jovyan}" "${NB_UID:-1001}" "${NB_GID:-1001}" "${HOME:-/home/${NB_USER:-jovyan}}" || true
fi

# If the SDKMAN directory exists but appears incomplete (missing init script),
# remove it so the installer can run cleanly. Creating an empty directory
# earlier in the build can cause the installer to detect a previous install
# and skip installation.
#
# This deliberately SUPERSEDES the upstream bootstrap script's own
# "already installed -> exit 0" guard: a silent skip on a half-written tree is
# what made 4aaf22d necessary.
if [ -d "$SDKMAN_DIR" ] && [ ! -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]; then
  echo "java-sdk: found existing $SDKMAN_DIR without init script — removing to allow fresh install"
  chown -R "${NB_UID:-1001}:${NB_GID:-1001}" "$SDKMAN_DIR" 2>/dev/null || true
  rm -rf "$SDKMAN_DIR" || true
fi

# ---------------------------------------------------------------------------
# The bootstrap archive is now PINNED, DIGEST-VERIFIED and MIRRORED.
#
# Until this commit the stage piped the upstream bootstrap SCRIPT into bash.
# That script performed a build-time egress of its own for the archive it
# serves, so a transient reset surfaced only as this pipeline's status and
# killed the leg with FH_SDKMAN_INSTALL_FAILED (curl (35), same class as the
# starship/gradle ports: runs 39053927880 / 39129344307).
#
# The archive that script downloads is byte-identical to the GitHub release
# asset below (its own download is a broker 302 to this asset, and the sha256
# matches through the redirect), so pinning it is NOT a version bump: 5.23.2
# is what is installed today. It is now mirrored through the toolcache exactly
# like gradle and starship: versions/versions.yaml (pin) + checksums.json
# (digest) + scripts/stage-toolcache.sh (TOOLS, tool_url) + this call site.
#
# What the archive does NOT contain — and what the bootstrap script used to
# SYNTHESISE around it — is the reason this file is longer than one download:
# the release zip carries only bin/, src/ and contrib/. No etc/, no libexec/,
# no var/. Every synthesised artefact is reproduced explicitly below (steps
# 1-7 in the target user's script) and then asserted by the post-conditions.
# Deliberately NOT reproduced: rc-file mutation (harmful in an image — PATH and
# JAVA_HOME are wired by the generated Dockerfile and /etc/profile.d/solen.sh),
# the separate native-CLI artefact (every call site in src/ is -f-guarded with
# a legacy bash fallback; the only observed loss is `sdk help` polish), and the
# existing-install guard named above.
# ---------------------------------------------------------------------------
# Resolution order matches features/java-gradle/install.sh: the pin first, then
# the transport. A missing SoT entry is a manifest defect and must name itself,
# not the helper that would have carried the fetch.
SDKMAN_CLI_VERSION="${SDKMAN_CLI_VERSION:-}"
if [ -z "$SDKMAN_CLI_VERSION" ] && command -v fh_resolve_version >/dev/null 2>&1; then
  SDKMAN_CLI_VERSION=$(fh_resolve_version "sdkman-cli" || true)
fi
if [ -z "$SDKMAN_CLI_VERSION" ]; then
  echo "❌ java-sdk: FH_VERSION_UNRESOLVED — pinned version for 'sdkman-cli' not found via SDKMAN_CLI_VERSION/fh_resolve_version; refusing to install an unpinned SDKMAN bootstrap (checksum-pinned tool)." >&2
  exit 1
fi

if ! command -v download_direct >/dev/null 2>&1; then
  echo "❌ java-sdk: FH_SDKMAN_INSTALL_FAILED — download_direct helper not found (features/_lib/download-release must run first); refusing to fall back to an unpinned bootstrap-script pipe. This stage exists to dodge exactly the transient public-CDN egress that the digest-pinned Harbor mirror removes." >&2
  exit 1
fi

# The payload is a zip, and the shared extractor is tar-centric, so the feature
# owns the unpack (java-gradle precedent). `zip` is declared here too, and NOT
# assumed transitive: it appears in no apt list in this repository, and base-image
# presence is not provable (tests/test_java_gradle_is_mirrored.py).
#
# Why `zip` and not only `unzip` — the mechanism matters, because it is invisible
# to a repo-side grep: NO script under src/ invokes zip. SDKMAN fetches the
# candidate's post-install hook at RUNTIME (src/sdkman-install.sh:148-151 curls
# ${SDKMAN_CANDIDATES_API}/hooks/post/<candidate>/<version>/<platform>, writes it,
# sources it, then calls __sdkman_post_installation_hook). The observed live body
# for java is "#Post Hook: linux-java-tarball", which runs `tar zxf
# "$binary_input"`, then `zip -qyr "$zip_output" .`, and at :73 `unzip -oq`. So
# `zip` is required by a script that is downloaded and executed later, on the
# consumer's machine — exactly the class of dependency a feature must declare
# rather than assume, and a missing zip would break `sdk install java` AFTER this
# stage reported success.
if ! command -v unzip >/dev/null 2>&1 || ! command -v zip >/dev/null 2>&1; then
  apt_install unzip zip || true
fi
if ! command -v unzip >/dev/null 2>&1; then
  echo "❌ java-sdk: FH_SDKMAN_INSTALL_FAILED — unzip is not available, so the pinned bootstrap archive cannot be extracted to $SDKMAN_DIR; refusing to publish an image that advertises SDKMAN and ships none." >&2
  exit 1
fi
if ! command -v zip >/dev/null 2>&1; then
  echo "❌ java-sdk: FH_SDKMAN_INSTALL_FAILED — zip is not available in the image. SDKMAN's candidate post-install step archives into \$SDKMAN_DIR/candidates with it, so a missing zip fails 'sdk install java' AFTER the download succeeded; failing here names the producer instead. Declared by this feature because java-sdkman owns the SDKMAN bootstrap." >&2
  exit 1
fi

# The toolcache key is $TOOLCACHE_DIR/sdkman-cli/$(basename "$url"), so this URL
# must stay byte-identical with the sdkman-cli arm of tool_url() in
# scripts/stage-toolcache.sh — the basename sdkman-cli-<version>.zip is
# load-bearing (tests/test_java_sdkman_is_mirrored.py pins the parity).
DOWNLOAD_URL="https://github.com/sdkman/sdkman-cli/releases/download/${SDKMAN_CLI_VERSION}/sdkman-cli-${SDKMAN_CLI_VERSION}.zip"

# extract=false (5th arg): fetch + digest-verify against checksums.json
# tools.sdkman-cli and hand the archive over unextracted at
# ${SCRATCH_DIR}/sdkman-cli; the layout below is this feature's job.
SCRATCH_DIR="${TMPDIR:-/tmp}/java-sdkman-bootstrap"
rm -rf "$SCRATCH_DIR"
mkdir -p "$SCRATCH_DIR"
fetch_rc=0
download_direct "$DOWNLOAD_URL" "sdkman-cli" "$SDKMAN_CLI_VERSION" "$SCRATCH_DIR" false || fetch_rc=$?
if [ "$fetch_rc" -ne 0 ]; then
  echo "❌ java-sdk: FH_SDKMAN_INSTALL_FAILED — download_direct of the pinned SDKMAN bootstrap archive (sdkman-cli-${SDKMAN_CLI_VERSION}.zip) exited ${fetch_rc}; SDKMAN was NOT installed. The archive is digest-verified against checksums.json tools.sdkman-cli and served from the toolcache mirror when staged. Aborting at the producer instead of letting java-jdk / java-maven / java-gradle report 'SDKMAN not available' minutes later and absorb the blame." >&2
  rm -rf "$SCRATCH_DIR" || true
  exit 1
fi
ARCHIVE="${SCRATCH_DIR}/sdkman-cli"
if [ ! -s "$ARCHIVE" ]; then
  echo "❌ java-sdk: FH_SDKMAN_INSTALL_FAILED — download_direct exited 0 but left no archive at ${ARCHIVE}; treating SDKMAN as not installed. The consumers this feature exists to serve (java-jdk, java-maven, java-gradle, kotlin) would each fail minutes later." >&2
  rm -rf "$SCRATCH_DIR" || true
  exit 1
fi
# The install itself runs as the target user (so every file lands in their home
# with their ownership, as the previous broker pipe did). Make the root-owned
# scratch readable so the su'd shell can consume the verified archive.
chmod 0755 "$SCRATCH_DIR"

# Run the install as the target non-root user so files land under their home
TMP_SCRIPT=$(mktemp)
cat > "$TMP_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SDKMAN_DIR="${SDKMAN_DIR:-$HOME/.sdkman}"
ARCHIVE="${FH_SDKMAN_ARCHIVE:?FH_SDKMAN_ARCHIVE must point at the digest-verified bootstrap archive}"
SDKMAN_CLI_VERSION="${FH_SDKMAN_VERSION:?FH_SDKMAN_VERSION must carry the pinned sdkman-cli version}"
export SDKMAN_DIR

# --- step 1: the directory skeleton the installer creates -------------------
# ext/ is find'ed unconditionally by sdkman-init.sh at source time and
# candidates/ backs the exported SDKMAN_CANDIDATES_DIR; both are fatal if
# absent, and neither is in the archive.
mkdir -p "$SDKMAN_DIR/tmp" "$SDKMAN_DIR/ext" "$SDKMAN_DIR/etc" "$SDKMAN_DIR/var" "$SDKMAN_DIR/candidates"

# --- step 2: var/platform ---------------------------------------------------
# infer_platform(), reproduced. The tokens are LOWERCASE on purpose: the API
# rejects LINUX64 with INVALID_PLATFORM (live probe). Builds are native per
# arch (no QEMU), so build-time uname == runtime arch and this file is correct
# for the machine that will run the image.
uname_s="$(uname -s)"
uname_m="$(uname -m)"
case "$uname_s" in
  Linux)
    case "$uname_m" in
      i686) SDKMAN_PLATFORM="linuxx32" ;;
      x86_64) SDKMAN_PLATFORM="linuxx64" ;;
      armv6l | armv7l | armv8l) SDKMAN_PLATFORM="linuxarm32hf" ;;
      aarch64) SDKMAN_PLATFORM="linuxarm64" ;;
      *) SDKMAN_PLATFORM="exotic" ;;
    esac
    ;;
  Darwin)
    case "$uname_m" in
      x86_64) SDKMAN_PLATFORM="darwinx64" ;;
      arm64) SDKMAN_PLATFORM="darwinarm64" ;;
      *) SDKMAN_PLATFORM="exotic" ;;
    esac
    ;;
  *) SDKMAN_PLATFORM="exotic" ;;
esac
export SDKMAN_PLATFORM
printf '%s\n' "$SDKMAN_PLATFORM" >"$SDKMAN_DIR/var/platform"

# --- step 3: etc/config -----------------------------------------------------
# Every key the installer appends, in its order, with the ci=true values
# already resolved (auto_answer / colour_enable / selfupdate_feature) and
# auto_complete=true, the branch taken for bash and zsh.
#
# sdkman_selfupdate_feature=false is load-bearing: at runtime `sdk selfupdate`
# pipes CANDIDATES_API/selfupdate/<channel>/<platform> into bash
# (src/sdkman-selfupdate.sh) and could rewrite src/ and silently undo this
# pinned install.
cat >"$SDKMAN_DIR/etc/config" <<'SDKMAN_CONFIG'
sdkman_auto_answer=true
sdkman_colour_enable=false
sdkman_selfupdate_feature=false
sdkman_auto_complete=true
sdkman_auto_env=false
sdkman_beta_channel=false
sdkman_checksum_enable=true
sdkman_curl_connect_timeout=7
sdkman_curl_max_time=10
sdkman_debug_mode=false
sdkman_healthcheck_enable=true
sdkman_insecure_ssl=false
sdkman_native_enable=true
SDKMAN_CONFIG

# --- step 4: var/candidates -------------------------------------------------
# The installer fetched the candidate list with a bare `curl -s` here, which
# leaves an EMPTY file on any transient failure — while sdkman-init.sh reads
# the file unconditionally at source time (SDKMAN_CANDIDATES_CSV=$(<...)), so
# existence and non-emptiness are mandatory and freshness is not. Seeded from
# the pinned snapshot instead: zero build-time egress, deterministic image
# contents, and ___sdkman_check_candidates_cache (src/sdkman-cache.sh, reached
# from sdkman-main.sh) refreshes it on first use.
printf '%s\n' 'activemq,ant,asciidoctorj,atmosphere,ballerina,bld,bpipe,btrace,concurnas,connor,cxf,detekt,doctoolchain,flink,gaiden,gcn,grace,gradle,gradleprofiler,grails,groovy,groovyserv,hadoop,helidon,hsc,http4k,jarviz,java,jbake,jbang,jeka,jenesis,jetty,jextract,jikkou,jmc,jmeter,joern,jpx,jqassistant,jreleaser,karaf,kcctl,ki,kobweb,kotlin,kotlintoolchain,kscript,kuml,layrry,leiningen,liquibase,maven,mcs,micronaut,mulefd,mvnd,mybatis,neo4jmigrations,pierrot,pomchecker,quarkus,sbt,scala,scalacli,schemacrawler,skeletal,spark,springboot,sshoogr,taxi,tomcat,toolkit,tornadovm,vertx,visualvm,webtau,znai' >"$SDKMAN_DIR/var/candidates"

# --- step 5: extract and flatten the archive --------------------------------
# Reproduced as the installer does it, WITHOUT --strip-components: unpack,
# delete any loose files left in the destination src/ by a previous install,
# copy the tree in, drop the unpacked root.
tmp_dir="$(mktemp -d)"
if ! unzip -qo "$ARCHIVE" -d "$tmp_dir"; then
  echo "FH_SDKMAN_INSTALL_FAILED: unzip of the digest-verified archive ${ARCHIVE} exited non-zero; SDKMAN was NOT installed." >&2
  rm -rf "$tmp_dir"
  exit 1
fi
if [ -d "$SDKMAN_DIR/src" ]; then
  find "$SDKMAN_DIR/src" -maxdepth 1 -type f -delete
fi
cp -rf "$tmp_dir"/sdkman-*/* "$SDKMAN_DIR"
rm -rf "$tmp_dir"/sdkman-*

# --- steps 6 + 7: the version stamps ----------------------------------------
# var/version is read by sdkman-version.sh; var/version_native is read by
# sdkman-selfupdate.sh with `<`, which ERRORS on a missing file — so it is
# required even though the native CLI is deliberately not installed.
printf '%s\n' "$SDKMAN_CLI_VERSION" >"$SDKMAN_DIR/var/version"
printf '%s\n' '0.7.34' >"$SDKMAN_DIR/var/version_native"

# Hard post-conditions: no init artefact means no SDKMAN, and an archive that
# unpacked but left the synthesised state behind is exactly the silent break
# the mirror could introduce. Checked here, in the target user's shell, because
# this is the shell whose $HOME was written to.
if [ ! -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]; then
  echo "FH_SDKMAN_INSTALL_FAILED: the SDKMAN bootstrap exited 0 but left no init artefact at $SDKMAN_DIR/bin/sdkman-init.sh (HOME=${HOME}); treating SDKMAN as not installed." >&2
  exit 1
fi
for synthesised in var/platform var/candidates etc/config var/version var/version_native; do
  if [ ! -s "$SDKMAN_DIR/$synthesised" ]; then
    echo "FH_SDKMAN_INSTALL_FAILED: the SDKMAN bootstrap unpacked but left no non-empty $synthesised under $SDKMAN_DIR (HOME=${HOME}); SDKMAN would source an unusable installation." >&2
    exit 1
  fi
done
if [ ! -d "$SDKMAN_DIR/candidates" ]; then
  echo "FH_SDKMAN_INSTALL_FAILED: $SDKMAN_DIR/candidates is missing; SDKMAN_CANDIDATES_DIR has no backing directory and every candidate install would fail." >&2
  exit 1
fi

# Avoid 'set -u' causing errors inside the SDKMAN init script
set +u
# shellcheck source=/dev/null
source "$SDKMAN_DIR/bin/sdkman-init.sh"
set -u
EOF

chown "${NB_UID:-1001}:${NB_GID:-1001}" "$TMP_SCRIPT" 2>/dev/null || true
# The install run's exit status is the first authoritative signal and must
# not be masked: a failing fetch, a missing init artefact or an unusable
# target account all mean this feature delivered nothing.
installer_rc=0
su - ${NB_USER:-jovyan} -s /bin/bash -c "FH_SDKMAN_ARCHIVE='$ARCHIVE' FH_SDKMAN_VERSION='$SDKMAN_CLI_VERSION' SDKMAN_DIR='$SDKMAN_DIR' bash '$TMP_SCRIPT'" || installer_rc=$?
rm -f "$TMP_SCRIPT"
rm -rf "$SCRATCH_DIR" || true
if [ "$installer_rc" -ne 0 ]; then
  echo "❌ java-sdk: FH_SDKMAN_INSTALL_FAILED — the SDKMAN bootstrap run for ${NB_USER:-jovyan} exited ${installer_rc}, so SDKMAN is not installed. Aborting at the producer instead of letting java-jdk / java-maven / java-gradle report 'SDKMAN not available' minutes later and absorb the blame (see the FH_SDKMAN_INSTALL_FAILED line above for the cause)." >&2
  exit 1
fi

# Try to source the initialization script for the active shell
if [ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]; then
  set +u
  # shellcheck source=/dev/null
  source "$SDKMAN_DIR/bin/sdkman-init.sh"
  set -u
fi

# Second post-condition, evaluated exactly the way every consumer evaluates
# it: as a login shell of the target user that sources the init script and
# then looks for `sdk`. Distinct exit statuses so the log says which
# guarantee broke instead of shrugging.
sdk_probe_rc=0
su - ${NB_USER:-jovyan} -s /bin/bash -lc 'set +u; [ -s "$HOME/.sdkman/bin/sdkman-init.sh" ] || exit 3; source "$HOME/.sdkman/bin/sdkman-init.sh" >/dev/null 2>&1 || exit 4; command -v sdk >/dev/null 2>&1 || exit 5; for f in var/platform var/candidates etc/config var/version var/version_native; do [ -s "$HOME/.sdkman/$f" ] || exit 6; done; [ -d "$HOME/.sdkman/candidates" ] || exit 6' || sdk_probe_rc=$?
if [ "$sdk_probe_rc" -ne 0 ]; then
  case "$sdk_probe_rc" in
    3) cause="no init artefact at \$HOME/.sdkman/bin/sdkman-init.sh for ${NB_USER:-jovyan}" ;;
    4) cause="sdkman-init.sh could not be sourced by ${NB_USER:-jovyan}" ;;
    5) cause="'sdk' is not resolvable for ${NB_USER:-jovyan} even after sourcing sdkman-init.sh" ;;
    6) cause="the synthesised SDKMAN state (var/platform, var/candidates, etc/config, var/version, var/version_native, candidates/) is missing or empty for ${NB_USER:-jovyan}" ;;
    *) cause="the SDKMAN probe for ${NB_USER:-jovyan} could not be executed (exit ${sdk_probe_rc})" ;;
  esac
  echo "❌ java-sdk: FH_SDKMAN_INSTALL_FAILED — ${cause}. SDKMAN is not usable by the consumers this feature exists to serve (java-jdk, java-maven, java-gradle, kotlin)." >&2
  exit 1
fi
echo "java-sdk: SDKMAN installed for ${NB_USER:-jovyan}"

# If running as root, ensure ownership of the SDKMAN directory matches the HOME owner
if [ "$(id -u)" -eq 0 ]; then
  if stat -c '%u:%g' "$HOME" >/dev/null 2>&1; then
    owner_gid=$(stat -c '%u:%g' "$HOME") || true
    [ -n "$owner_gid" ] && chown -R "$owner_gid" "$SDKMAN_DIR" 2>/dev/null || true
  else
    if [ -n "${NB_USER:-}" ]; then
      chown -R "${NB_USER}:${NB_GID:-}" "$SDKMAN_DIR" 2>/dev/null || true
    fi
  fi
fi

echo "java-sdk: SDKMAN installation complete"
echo "java-sdk: Use java-jdk, java-maven, or java-gradle features to install tools"
exit 0
