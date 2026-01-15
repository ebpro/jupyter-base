#!/usr/bin/env bash
# Small shim to expose feature helper functions to feature install scripts during build
set -euo pipefail
# Source the library under scripts/lib if present
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/lib/features.sh" ]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/features.sh"
elif [ -f "/opt/solen/_lib/helpers.sh" ]; then
  # Fallback: use the helper file copied into the image at build time
  # shellcheck disable=SC1091
  source "/opt/solen/_lib/helpers.sh"
fi
