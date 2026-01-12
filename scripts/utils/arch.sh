#!/usr/bin/env bash
set -euo pipefail

# Helper functions to normalize architecture names and provide common aliases
# Usage:
#   arch_map <input>       -> outputs canonical arch (amd64, arm64, arm, ppc64le, s390x, riscv64)
#   arch_aliases <canon>   -> outputs space-separated possible asset name variants

arch_map() {
  local in=${1:-}
  case "$in" in
    linux/amd64|amd64|x86_64|X86_64) echo amd64 ;;
    linux/arm64|arm64|aarch64|aarch64_be) echo arm64 ;;
    linux/arm/v7|linux/arm/v6|armv7l|armv7|armhf|arm) echo arm ;;
    ppc64le) echo ppc64le ;;
    s390x) echo s390x ;;
    riscv64) echo riscv64 ;;
    *) echo amd64 ;;
  esac
}

arch_aliases() {
  case "$1" in
    amd64) echo "amd64 x86_64" ;;
    arm64) echo "arm64 aarch64 armv8" ;;
    arm) echo "arm armv7l armhf" ;;
    ppc64le) echo "ppc64le" ;;
    s390x) echo "s390x" ;;
    riscv64) echo "riscv64" ;;
    *) echo "$1" ;;
  esac
}

export -f arch_map arch_aliases
