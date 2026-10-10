# Auto-inserted by scripts/inject_prebaked_helpers.sh
# Source shared feature helpers (prebaked into image) or fall back to repository helper
if [ -n "${FEATURE_HELPERS_DIR:-}" ] && [ -f "${FEATURE_HELPERS_DIR}/helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "${FEATURE_HELPERS_DIR}/helpers.sh"
elif [ -f "../../../scripts/feature_helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "../../../scripts/feature_helpers.sh"
fi
#!/usr/bin/env bash
set -euo pipefail

# graalvm install skeleton
GRAALVM_VERSION=${GRAALVM_VERSION:-${1:-22.3.1}}
INSTALL_NATIVE_IMAGE=${INSTALL_NATIVE_IMAGE:-true}

echo "graalvm: installing GraalVM ${GRAALVM_VERSION} (native-image=${INSTALL_NATIVE_IMAGE})"

# Use SDKMAN exclusively; default candidate is graalvm-ce unless overridden
if ! command -v sdk >/dev/null 2>&1; then
  echo "graalvm: SDKMAN not available. Please enable SDKMAN in the base image or devcontainer." >&2
  exit 1
fi

DIST_ID="${SDKMAN_GRAALVM_IDENTIFIER:-graalvm-ce}"
if [ -n "$GRAALVM_VERSION" ]; then
  CAND="${DIST_ID}-${GRAALVM_VERSION}"
else
  CAND="$DIST_ID"
fi
echo "graalvm: running: sdk install java ${CAND}"
sdk install java "${CAND}" || sdk install java "${DIST_ID}" || true

if [ "$INSTALL_NATIVE_IMAGE" = "true" ]; then
  echo "graalvm: native-image component may need to be installed (use 'gu' from GraalVM to install native-image)"
fi

echo "graalvm: done"
