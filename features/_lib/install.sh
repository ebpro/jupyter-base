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
# Source fh_helpers if available (provides fh_resolve_version, fh_resolve_checksum, etc.)
if [ -n "${FEATURE_HELPERS_DIR:-}" ] && [ -f "${FEATURE_HELPERS_DIR}/fh_helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "${FEATURE_HELPERS_DIR}/fh_helpers.sh"
elif [ -f "../../../features/_lib/fh_helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "../../../features/_lib/fh_helpers.sh"
fi
set -euo pipefail
# No-op helper feature directory marker. Subfeatures live in subdirectories.
echo "_lib helper placeholder (no-op)"
exit 0
