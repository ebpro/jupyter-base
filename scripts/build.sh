#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GENERATE="$ROOT/scripts/generate-dockerfile.sh"
GENERATE_BAKE="$ROOT/scripts/generate-bake.sh"
VALIDATE_PROFILES="$ROOT/scripts/validate-profiles.sh"
VALIDATE_FEATURES="$ROOT/scripts/validate_features.py"

usage(){
  cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  generate [--all-profiles] [--out FILE]   Generate Dockerfile(s)
  validate                                 Run profile and feature validators
  preview                                  Preview bake plan (safe --print)
  build-one --profile NAME [--platform PL] [--push]  Build one profile target
  build-all [--platform PL] [--push]       Generate bake and run buildx bake
  help

Examples:
  $(basename "$0") generate --all-profiles
  $(basename "$0") build-one --profile 00-01-minimal --platform linux/amd64,linux/arm64
  $(basename "$0") build-all --platform linux/amd64,linux/arm64 --push
EOF
}

cmd=${1:-help}
shift || true

check_buildx(){
  if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker CLI not found on PATH" >&2; return 2
  fi
  if ! docker buildx version >/dev/null 2>&1; then
    echo "ERROR: docker buildx not available" >&2; return 2
  fi
}

case "$cmd" in
  generate)
    ALL=false
    OUT="Dockerfile.generated"
    while [[ $# -gt 0 ]]; do
      case $1 in
        --all-profiles) ALL=true; shift ;;
        --out) OUT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 2 ;;
      esac
    done
    if [ "$ALL" = true ]; then
      bash "$GENERATE" --all-profiles --out "$OUT"
    else
      bash "$GENERATE" --out "$OUT"
    fi
    ;;

  validate)
    bash "$VALIDATE_PROFILES" || true
    python3 "$VALIDATE_FEATURES" || true
    ;;

  preview)
    check_buildx
    export REPO=${REPO:-${REPO:-}}
    docker buildx bake --file docker-bake.generated.hcl --print all
    ;;

  build-one)
    PROFILE=""
    PLAT="linux/amd64"
    PUSH=false
    while [[ $# -gt 0 ]]; do
      case $1 in
        --profile) PROFILE="$2"; shift 2 ;;
        --platform) PLAT="$2"; shift 2 ;;
        --push) PUSH=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 2 ;;
      esac
    done
    if [ -z "$PROFILE" ]; then echo "--profile is required"; exit 2; fi
    # Generate single-profile Dockerfile
    bash "$GENERATE" --profile "$PROFILE" --out Dockerfile.generated
    check_buildx
    # create or use builder
    docker buildx inspect jb-builder >/dev/null 2>&1 || docker buildx create --name jb-builder --driver docker-container --use
    if [ "$PUSH" = true ]; then
      docker buildx build --platform "$PLAT" -f Dockerfile.generated --target final-$PROFILE --push -t "${REPO:-$(basename "$PWD")}/${IMAGE_NAME:-solen}:$PROFILE" .
    else
      docker buildx build --platform "$PLAT" -f Dockerfile.generated --target final-$PROFILE --load -t "${REPO:-$(basename "$PWD")}/${IMAGE_NAME:-solen}:$PROFILE" .
    fi
    ;;

  build-all)
    PLAT=${PLATFORM:-}
    PUSH=false
    while [[ $# -gt 0 ]]; do
      case $1 in
        --platform) PLAT="$2"; shift 2 ;;
        --push) PUSH=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 2 ;;
      esac
    done
    # Generate all profiles and bake file
    bash "$GENERATE" --all-profiles --out Dockerfile.generated
    # Setup bake env
    if [ -z "$PLAT" ]; then
      PLAT="linux/amd64"
    fi
    export BAKE_PLATFORMS="$PLAT"
    # derive arch tokens
    BAKE_ARCHS="${PLAT//linux\//}"
    export BAKE_ARCHS
    export REPO=${REPO:-${REPO:-}}
    export IMAGE_NAME=${IMAGE_NAME:-solen}
    export TAG1=${TAG1:-latest}
    export TAG2=${TAG2:-latest-sha}
    bash "$GENERATE_BAKE"
    check_buildx
    if [ "$PUSH" = true ]; then
      docker buildx bake --file docker-bake.generated.hcl all
    else
      docker buildx bake --file docker-bake.generated.hcl --print all
    fi
    ;;

  help|-h|--help)
    usage
    ;;

  *)
    echo "Unknown command: $cmd" >&2
    usage
    exit 2
    ;;
esac

exit 0
