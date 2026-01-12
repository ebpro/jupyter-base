#!/usr/bin/env bash
set -euo pipefail

# Wrapper for backwards compatibility: call the new script name
exec "$(dirname "$0")/update-checksums.sh" "$@"
