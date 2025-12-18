#!/usr/bin/env bash
set -euo pipefail

# Shared helpers for build scripts

check_buildx() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker CLI not found on PATH" >&2; return 2
  fi
  if ! docker buildx version >/dev/null 2>&1; then
    echo "ERROR: docker buildx not available" >&2; return 2
  fi
}

create_builder_if_missing() {
  local name=${1:-jb-builder}
  if ! docker buildx inspect "$name" >/dev/null 2>&1; then
    docker buildx create --name "$name" --driver docker-container --use
  else
    docker buildx use "$name"
  fi
}

normalize_platforms() {
  local raw="$1"
  local out=""
  IFS=',' read -r -a parts <<< "$raw"
  for part in "${parts[@]}"; do
    part="$(echo "$part" | sed -e 's/^\s*//' -e 's/\s*$//')"
    [ -z "$part" ] && continue
    if [[ "$part" == linux/* ]]; then
      canon=${part#linux/}
    else
      canon=$part
    fi
    if [ -z "$out" ]; then
      out="linux/$canon"
    else
      out+=",linux/$canon"
    fi
  done
  echo "$out"
}
