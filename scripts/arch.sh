#!/usr/bin/env bash
# Lightweight shim to expose `arch_map` and `arch_aliases` at `scripts/arch.sh`
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/utils/arch.sh" ]; then
  # shellcheck source=/dev/null
  . "${SCRIPT_DIR}/utils/arch.sh"
else
  echo "WARN: scripts/utils/arch.sh not found; arch_map will be unavailable" >&2
fi
