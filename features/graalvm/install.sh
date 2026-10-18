#!/usr/bin/env bash
# Auto-inserted by scripts/inject_prebaked_helpers.sh
# Source shared feature helpers (prebaked into image) or fall back to repository helper
if [ -n "${FEATURE_HELPERS_DIR:-}" ] && [ -f "${FEATURE_HELPERS_DIR}/helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "${FEATURE_HELPERS_DIR}/helpers.sh"
elif [ -f "../../../scripts/feature_helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "../../../scripts/feature_helpers.sh"
fi
set -euo pipefail

# graalvm install skeleton
NB_USER=${NB_USER:-jovyan}
# `GRAALVM_VERSION` historically carried *GraalVM release* numbering (22.3.1
# and friends). SDKMAN's `java` candidate has never used that numbering, so the
# value is no longer composed into a candidate id -- see the resolution below.
GRAALVM_VERSION=${GRAALVM_VERSION:-${1:-}}
INSTALL_NATIVE_IMAGE=${INSTALL_NATIVE_IMAGE:-true}

# SDKMAN identifies a GraalVM `java` candidate as <version>-graalce
# (Community) or <version>-graal (Oracle): 25.4.4.1+1-graalce, 21.0.2-graalce,
# 17.0.12-graal. The CE default below is present on BOTH catalog arches
# (linuxx64 and linuxarm64, checked against the live catalog) and is the
# JDK-25 pairing this repo standardises on (lang-java-25, quarto-java-25).
#
# The previous default composed `graalvm-ce-22.3.1` and fell back to the bare
# `graalvm-ce`; neither string exists anywhere in the catalog, so
# `sdk install java` deterministically hit SDKMAN's "not a valid version" path
# on every build and the trailing `|| true` discarded that status. The result
# was measured, not guessed: `verify-published` (job 117502438116) died on
# `run-check-env.sh: line 30: java: command not found`, because lang-java-graal
# -- the only java profile without java-jdk, and java-sdkman installs no java
# candidate -- shipped an image with no java at all while its feature.json
# advertises `java`, `javac` and `graalvm`.
GRAALVM_CE_DEFAULT="25.4.4.1+1-graalce"

echo "graalvm: installing GraalVM via SDKMAN (native-image=${INSTALL_NATIVE_IMAGE})"

# SDKMAN may be installed but not on PATH in non-login shells.
# Source the init script to make `sdk` available.
if [ -f "${HOME}/.sdkman/bin/sdkman-init.sh" ]; then
    set +u; source "${HOME}/.sdkman/bin/sdkman-init.sh"; set -u
elif [ -f "/home/jovyan/.sdkman/bin/sdkman-init.sh" ]; then
    set +u; source "/home/jovyan/.sdkman/bin/sdkman-init.sh"; set -u
fi

# Use SDKMAN exclusively; the java candidate id is resolved below.
if ! command -v sdk >/dev/null 2>&1; then
  echo "graalvm: SDKMAN not available. Please enable SDKMAN in the base image or devcontainer." >&2
  exit 1
fi

# Candidate resolution. SDKMAN_GRAALVM_IDENTIFIER wins and is taken verbatim;
# otherwise a GRAALVM_VERSION that already carries the candidate suffix is
# taken verbatim; anything else (legacy GraalVM release numbering) resolves to
# the CE default and says so on stderr, instead of composing a string the
# catalog cannot resolve. The old `|| sdk install java graalvm-ce` fallback is
# gone: the bare candidate name is not a catalog id either, so the chain could
# only ever produce a second rejection.
CAND="${SDKMAN_GRAALVM_IDENTIFIER:-}"
if [ -z "$CAND" ]; then
  case "$GRAALVM_VERSION" in
    "")
      CAND="$GRAALVM_CE_DEFAULT"
      ;;
    *-graalce | *-graal)
      CAND="$GRAALVM_VERSION"
      ;;
    *)
      CAND="$GRAALVM_CE_DEFAULT"
      echo "graalvm: WARNING - ignoring legacy GRAALVM_VERSION='${GRAALVM_VERSION}': GraalVM release numbering has no SDKMAN 'java' candidate id (the scheme is <version>-graalce / <version>-graal), so it could only resolve to a version SDKMAN rejects. Installing '${CAND}'; select another distribution by putting the complete candidate id in GRAALVM_VERSION or SDKMAN_GRAALVM_IDENTIFIER." >&2
      ;;
  esac
fi

echo "graalvm: running: sdk install java ${CAND}"

# `sdk` is a shell function provided by sdkman-init.sh, and the installer it
# sources references $3 without a default, so nounset comes off around the
# call only. The call runs in a login shell of the target user that sources
# the init script itself -- the shape proven by java-maven at c5af458: during
# the feature loop a bare login shell has no SDKMAN on PATH, because
# /etc/profile.d/solen.sh is written by the RUN that follows the loop.
GRAAL_SDK_CMD="sdk install java ${CAND}"
install_rc=0
su - ${NB_USER} -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; ${GRAAL_SDK_CMD}" || install_rc=$?
if [ "$install_rc" -ne 0 ]; then
  echo "❌ graalvm: FH_GRAALVM_INSTALL_FAILED — '${GRAAL_SDK_CMD}' exited ${install_rc} for user ${NB_USER}, so no GraalVM was installed. '${CAND}' is not resolvable in the SDKMAN java catalog (https://api.sdkman.io/2/candidates/java/<platform>/versions/list). This stage performs a build-time network fetch through the SDKMAN installed by the java-sdkman feature; aborting at the producer rather than publishing an image whose feature.json provides java, javac and graalvm." >&2
  exit 1
fi

if [ "$INSTALL_NATIVE_IMAGE" = "true" ]; then
  echo "graalvm: native-image component may need to be installed (use 'gu' from GraalVM to install native-image)"
fi

# Verify installation: the post-condition for the install above.
#
# `java` is reachable only through $HOME/.sdkman/candidates/java/current/bin,
# which sdkman-init.sh exports, so the probe sources the init script instead of
# trusting a bare login shell. Distinct exit statuses so the log says which
# guarantee broke rather than shrugging: a zero exit from `sdk install` proves
# nothing on its own (that is precisely the shape the removed `|| true` hid).
graal_probe_rc=0
su - ${NB_USER} -s /bin/bash -lc 'set +u; [ -s "$HOME/.sdkman/bin/sdkman-init.sh" ] || exit 3; source "$HOME/.sdkman/bin/sdkman-init.sh" >/dev/null 2>&1 || exit 4; [ -x "$HOME/.sdkman/candidates/java/current/bin/java" ] || exit 6; command -v java >/dev/null 2>&1 || exit 5; java -version 2>&1 | grep -qi "graalvm" || exit 7' || graal_probe_rc=$?
if [ "$graal_probe_rc" -ne 0 ]; then
  case "$graal_probe_rc" in
    3) cause="no init artefact at \$HOME/.sdkman/bin/sdkman-init.sh for ${NB_USER}" ;;
    4) cause="sdkman-init.sh could not be sourced by ${NB_USER}" ;;
    6) cause="no candidate binary at \$HOME/.sdkman/candidates/java/current/bin/java for ${NB_USER} ('${CAND}' installed nothing)" ;;
    5) cause="'java' is not resolvable for ${NB_USER} even after sourcing sdkman-init.sh" ;;
    7) cause="\$HOME/.sdkman/candidates/java/current/bin/java does not report a GraalVM runtime ('${CAND}')" ;;
    *) cause="the GraalVM probe for ${NB_USER} could not be executed (exit ${graal_probe_rc})" ;;
  esac
  echo "❌ graalvm: FH_GRAALVM_NOT_AVAILABLE — ${cause}. Aborting rather than publishing an image that advertises java/javac/graalvm (features/graalvm/feature.json) and ships none." >&2
  exit 1
fi

echo "graalvm: done (GraalVM '${CAND}' installed for ${NB_USER} and verified)"
