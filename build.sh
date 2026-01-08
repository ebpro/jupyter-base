#!/bin/bash
set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# CLI runtime flags
DRY_RUN=false
QUIET=false
PROGRESS=plain

# Git version detection functions
get_git_tag() {
    git describe --tags --exact-match 2>/dev/null || echo ""
}

get_git_sha() {
    git rev-parse --short HEAD 2>/dev/null || echo "unknown"
}

get_git_branch() {
    git rev-parse --abbrev-ref HEAD 2>/dev/null | tr '/' '-' || echo "main"
}

get_version_tags() {
    # Return primary tags (primary, secondary) derived from git state
    local git_tag=$(get_git_tag)
    local git_sha_short=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    local git_branch=$(get_git_branch)

    if [[ -n "${git_tag}" ]]; then
        # For annotated tags, use tag and tag-sha
        echo "${git_tag} ${git_tag}-${git_sha_short}"
    elif [[ "${git_branch}" == "main" || "${git_branch}" == "master" ]]; then
        # For main/master, prefer 'latest' and branch-sha
        echo "latest ${git_branch}-${git_sha_short}"
    else
        # For feature branches, use branch and branch-sha
        echo "${git_branch} ${git_branch}-${git_sha_short}"
    fi
}

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)/scripts"
if [ -f "$SCRIPTS_DIR/arch.sh" ]; then
    # shellcheck source=/dev/null
    . "$SCRIPTS_DIR/arch.sh"
fi

# Source shared build helpers if available
## Embedded helpers from scripts/lib-build.sh
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

# Support legacy subcommand-style invocations (generate|validate|preview|build-one|build-all)
if [ "$#" -gt 0 ]; then
    case "$1" in
        generate)
            shift
            # pass through args to generator
            bash "${PWD}/scripts/generate-dockerfile.sh" "$@"
            exit $?
            ;;
        validate)
            shift
            bash "${PWD}/scripts/validate-profiles.sh" || true
            python3 "${PWD}/scripts/validate_features.py" || true
            exit 0
            ;;
        preview)
            shift
            check_buildx || exit 2
            export REPO=${REPO:-${REPO:-}}
            docker buildx bake --file docker-bake.generated.hcl --print all
            exit $?
            ;;
        build-one)
            # translate subcommand-style to flag-style and continue parsing
            shift
            # extract supported options: --profile <name> --platform <pl> --push
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --profile) PROFILE="$2"; shift 2 ;;
                    --platform) TARGET_PLATFORM="$2"; shift 2 ;;
                    --push) PUSH=true; shift ;;
                    -h|--help) echo "Usage: build-one --profile NAME [--platform PL] [--push]"; exit 0 ;;
                    *) echo "Unknown option for build-one: $1"; exit 2 ;;
                esac
            done
            # clear positional params so main parser won't run again
            set --
            ;;
        build-all)
            shift
            # translate build-all options: --platform, --push
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --platform) TARGET_PLATFORM="$2"; shift 2 ;;
                    --push) PUSH=true; shift ;;
                    -h|--help) echo "Usage: build-all [--platform PL] [--push]"; exit 0 ;;
                    *) echo "Unknown option for build-all: $1"; exit 2 ;;
                esac
            done
            set --
            ;;
        *)
            # not a subcommand, continue normal flag parsing
            ;;
    esac
fi

# Platform detection functions
detect_build_platform() {
    # canonicalize host arch (uname -m -> amd64/arm64/...)
    local host=$(uname -m)
    local canon=$(arch_map "$host")
    echo "linux/$canon"
}

normalize_platforms() {
    # input: comma-separated list of arch tokens (e.g. amd64,arm64 or linux/amd64)
    local raw="$1"
    local out=""
    IFS=',' read -r -a parts <<< "$raw"
    for part in "${parts[@]}"; do
        part="$(echo "$part" | sed -e 's/^\s*//' -e 's/\s*$//')"
        [ -z "$part" ] && continue
        local canon=$(arch_map "$part")
        if [ -z "$out" ]; then
            out="linux/$canon"
        else
            out+=",linux/$canon"
        fi
    done
    echo "$out"
}

docker_buildx_available() {
    # Prefer `docker buildx version` if docker present, otherwise fallback to docker-buildx binary
    if command -v docker >/dev/null 2>&1; then
        if docker buildx version >/dev/null 2>&1; then
            return 0
        fi
    fi
    if command -v docker-buildx >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Check Git state
check_git_state() {
    if ! git diff --quiet 2>/dev/null; then
        log_warn "Git repository has uncommitted changes"
        return 1
    fi
    return 0
}

# Default values
REPO=${REPO:-ghcr.io/ebpro}
IMAGE_NAME=${PWD##*/}
read -r TAG1 TAG2 <<< "$(get_version_tags)"
GIT_SHA=$(get_git_sha)
GIT_SHA_SHORT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_BRANCH=$(get_git_branch)
FULL_GIT_SHA=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
BUILD_PLATFORM=$(detect_build_platform)
# If PLATFORM env provided, normalize it. Otherwise default to host build platform
if [ -n "${PLATFORM:-}" ]; then
    TARGET_PLATFORM=$(normalize_platforms "$PLATFORM")
else
    TARGET_PLATFORM="$BUILD_PLATFORM"
fi

# Multi-arch flag (set via CLI) or env `ARCHS` to choose explicit architectures when requested
ALL_ARCHS=false

# Build tag canonicalization: include commit and build metadata as additional tags
BUILD_DATE_UTC=$(date -u +'%Y%m%dT%H%M%SZ')
# Compose a list of tags we will apply to the final image(s). Keep them ordered by usefulness.
TAGS_LIST=()
# Primary tags from get_version_tags are already in TAG1 and TAG2
TAGS_LIST+=("${TAG1}")
if [ -n "${TAG2}" ]; then
    TAGS_LIST+=("${TAG2}")
fi
# Add short sha tag for traceability (skip branch-shortsha since TAG2 already has it)
TAGS_LIST+=("${GIT_SHA_SHORT}")
# Add a build-date tag to help identify the build
TAGS_LIST+=("build-${BUILD_DATE_UTC}")

# Logging functions
log_info() { echo -e "${GREEN}INFO: $1${NC}"; }
log_warn() { echo -e "${YELLOW}WARN: $1${NC}"; }
log_error() { echo -e "${RED}ERROR: $1${NC}" >&2; }

# Help message
show_help() {
    cat <<'EOF'
Usage: $(basename "$0") [options]

Build Docker image with specified options.

Options:
    -h, --help          Show this help message
    -r, --repo          Docker repository name (default: ${REPO})
    -t, --tag           Custom tag (default: ${TAG1})
    -p, --platform      Build platform (default: ${TARGET_PLATFORM})
    --push              Push image after build
    --build-codeserver  Build a codeserver image based on the built image using `Dockerfile.codeserver`
    --all-architectures  Build images for multiple architectures (uses ARCHS env or default amd64,arm64)
    --load              Attempt to load multi-platform images locally (may not work with all platforms)
    --profile <name>    Generate a Dockerfile from profile and build it
    --generate-only     Only generate Dockerfile/devcontainer and exit
    --dry-run           Print the build command but do not execute it
    --quiet             Disable colored output
    --list-profiles     List available profiles and their build targets
    --progress <mode>   Set buildx progress mode (auto|plain|tty). Default: plain

Build Information:
    Build Platform: ${BUILD_PLATFORM}
    Target Platform(s): ${TARGET_PLATFORM}
    Repository: ${REPO}
    Image: ${IMAGE_NAME}
    Tags: ${TAG1}, ${TAG2}

Git Information:
    Branch: $(get_git_branch)
    Commit: $(get_git_sha)
    Tag: $(get_git_tag)
EOF
}

# Parse arguments
PUSH=false
LOAD=false
BUILD_CODESERVER=false
PROFILE=""
GENERATE_ONLY=false
DOCKERFILE="Dockerfile"
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) show_help; exit 0 ;;
        -r|--repo) REPO="$2"; shift 2 ;;
        -t|--tag) TAG1="$2" TAG2="${2}-${GIT_SHA}"; shift 2 ;;
        -p|--platform) TARGET_PLATFORM="$2"; shift 2 ;;
        --push) PUSH=true; shift ;;
        --build-codeserver|--codeserver) BUILD_CODESERVER=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --quiet) QUIET=true; shift ;;
        --load) LOAD=true; shift ;;
        --progress) PROGRESS="$2"; shift 2 ;;
        --all-architectures) ALL_ARCHS=true; shift ;;
        --profile) PROFILE="$2"; shift 2 ;;
        --generate-only) GENERATE_ONLY=true; shift ;;
        --all-profiles) ALL_PROFILES=true; shift ;;
        --list-profiles) LIST_PROFILES=true; shift ;;
        *) break ;;
    esac
done

# If quiet requested, disable color sequences
if [ "${QUIET}" = true ]; then
    GREEN=''
    YELLOW=''
    RED=''
    NC=''
fi

# Check Git state before building
check_git_state || log_warn "Consider committing changes before building"

# If user asked to list profiles/targets, print them and exit
if [ "${LIST_PROFILES:-false}" = true ]; then
    echo "Available profiles (from 'profiles/' directory):"
    if [ -d "profiles" ]; then
        for p in profiles/*; do
            [ ! -e "$p" ] && continue
            name=$(basename "$p")
            [ "$name" = "README.md" ] && continue
            # create slug by stripping leading numeric prefixes like "20-00-"
            slug=$(echo "$name" | sed -E 's/^[0-9]+(-[0-9]+)*-//')
            printf ' - %s (slug: %s) -> build target: final-%s\n' "$name" "$slug" "$slug"
        done
    else
        echo " (no 'profiles/' directory found)"
    fi

    # Also attempt to list build stages in common Dockerfiles
    echo
    echo "Detected build stages in Dockerfile(s):"
    found=false
    for df in Dockerfile Dockerfile.generated; do
        [ ! -f "$df" ] && continue
        echo " - $df:"
        # Find 'AS name' occurrences (case-insensitive)
        awk 'BEGIN{IGNORECASE=1} /FROM/ && / AS / { for(i=1;i<=NF;i++) if(toupper($i)=="AS") print "    " $(i+1) }' "$df" | sort -u | while read -r stage; do
            found=true
            echo "$stage"
        done
    done
    if [ "$found" = false ]; then
        echo "   (no named stages found in Dockerfile or Dockerfile.generated)"
    fi
    exit 0
fi

# Default behavior: always generate the canonical Dockerfile with all profiles
# (the `--profile` option will still select which `final-<profile>` target to build)
log_info "Generating matrix profiles and devcontainers"
# First generate matrix profiles from YAML definitions
bash "${PWD}/scripts/generate-all-matrix-profiles.sh" || true
# Then generate Dockerfile for all profiles
log_info "Generating Dockerfile for all profiles (default)"
bash "${PWD}/scripts/generate-dockerfile.sh" --all-profiles --out Dockerfile.generated
# Generate devcontainer for single profile if requested
if [ -n "${PROFILE:-}" ]; then
    python3 "${PWD}/scripts/generate-devcontainer-json.py" "$PROFILE" || true
fi
DOCKERFILE="Dockerfile.generated"
if [ "${GENERATE_ONLY}" = true ]; then
    log_info "Generation complete; exiting due to --generate-only"
    exit 0
fi

if [ "${ALL_PROFILES:-false}" = true ]; then
    log_info "Generating matrix profiles and devcontainers for all profiles"
    # Generate matrix profiles from YAML definitions
    bash "${PWD}/scripts/generate-all-matrix-profiles.sh" || true
    # Generate Dockerfile for all profiles
    bash "${PWD}/scripts/generate-dockerfile.sh" --all-profiles --out Dockerfile.generated
    # Generate devcontainers for all profiles (matrix + hand-written)
    bash "${PWD}/scripts/generate-all-devcontainers.sh" || true
    # Prepare bake platforms and archs for HCL generation
    if [ "${ALL_ARCHS}" = true ]; then
        RAW_ARCHS="${ARCHS:-amd64,arm64}"
        BAKE_PLATFORMS=$(normalize_platforms "$RAW_ARCHS")
    else
        # TARGET_PLATFORM may already be normalized (linux/amd64) or comma list
        BAKE_PLATFORMS="$TARGET_PLATFORM"
    fi
    # derive arch tokens (strip linux/ prefix)
    BAKE_ARCHS=""
    IFS=',' read -r -a _parts <<< "$BAKE_PLATFORMS"
    for pp in "${_parts[@]}"; do
        arch=${pp#linux/}
        if [ -z "$BAKE_ARCHS" ]; then
            BAKE_ARCHS="$arch"
        else
            BAKE_ARCHS+=",$arch"
        fi
    done
    # Export variables used by the bake generator (include TAGS_CSV for tagging guidance)
    TAGS_CSV=$(IFS=,; echo "${TAGS_LIST[*]}")
    export REPO IMAGE_NAME TAG1 TAG2 BAKE_PLATFORMS BAKE_ARCHS TAGS_CSV
    bash "${PWD}/scripts/generate-bake.sh" || true
    DOCKERFILE="Dockerfile.generated"
    if [ "${GENERATE_ONLY}" = true ]; then
        log_info "Generation complete; exiting due to --generate-only"
        exit 0
    fi
    # Build via bake if available
    if docker_buildx_available; then
        log_info "Attempting to build all profiles via docker buildx bake"
        # Explicitly target the generated "all" group so `bake` doesn't look for a missing default
        # Use the bake platforms computed earlier (BAKE_PLATFORMS) so generated HCL gets correct platforms
        BAKE_CMD=(docker buildx bake -f docker-bake.generated.hcl all --set "*.platform=${BAKE_PLATFORMS}")
        if [ "${PUSH}" = true ]; then
            BAKE_CMD+=(--push)
        fi
        # If the user requested --load, instruct bake to output to the local docker daemon
        # Note: loading multi-platform builds into the local daemon only works for single-arch
        # builds or on compatible setups. This tells bake to use the docker output driver.
        if [ "${LOAD}" = true ]; then
            BAKE_CMD+=(--set "*.output=type=docker")
        fi
        "${BAKE_CMD[@]}"
        log_info "Bake completed"
        exit 0
    else
        log_warn "buildx not available; falling back to per-profile builds"
        for p in profiles/*; do
            prof=$(basename "$p")
            [ "$prof" = "README.md" ] && continue
            log_info "Building profile: $prof"
            docker buildx build --platform=${TARGET_PLATFORM} -f Dockerfile.generated --target final-$prof -t "${REPO}/${IMAGE_NAME}:${prof}-${TAG1}" ${LOAD:+--load} ${PUSH:+--push} . || true
        done
        exit 0
    fi
fi

# If user requested all architectures, generate canonical list from ARCHS env or default
if [ "${ALL_ARCHS}" = true ]; then
    RAW_ARCHS="${ARCHS:-amd64,arm64}"
    TARGET_PLATFORM=$(normalize_platforms "$RAW_ARCHS")
    log_info "Building for architectures: $TARGET_PLATFORM"
fi

# Setup buildx builder for multi-platform builds if needed
if [[ "${TARGET_PLATFORM}" == *","* ]]; then
    log_info "Multi-platform build detected: ${TARGET_PLATFORM}"

    # Check if we have a suitable builder
    BUILDER_NAME="multi-platform-builder"
    if ! docker buildx inspect "${BUILDER_NAME}" &>/dev/null; then
        log_info "Creating new buildx builder: ${BUILDER_NAME}"
        docker buildx create --name "${BUILDER_NAME}" --use --driver docker-container
    else
        log_info "Using existing buildx builder: ${BUILDER_NAME}"
        docker buildx use "${BUILDER_NAME}"
    fi

    # For multi-platform, we need to either push or use a local cache
    BUILD_ARGS=("--platform=${TARGET_PLATFORM}")
    if [[ "${PUSH}" == "true" ]]; then
        BUILD_ARGS+=("--push")
    elif [[ "${LOAD}" == "true" ]]; then
        # Try to load multi-platform images locally
        BUILD_ARGS+=("--load")
        log_info "Attempting to load multi-platform images locally"
        log_warn "Loading may only work for compatible architectures with your host"
    else
        BUILD_ARGS+=("--output=type=image,push=false")
        log_warn "Building multi-platform image without pushing. Images may not be available locally."
        log_warn "Use --push to push to registry or --load to attempt loading locally."
    fi
else
    # Single platform build
    BUILD_ARGS=("--platform=${TARGET_PLATFORM}")

    # For single platform, we can always load unless push is specified
    if [[ "${PUSH}" == "true" ]]; then
        BUILD_ARGS+=("--push")
    else
        BUILD_ARGS+=("--load")
    fi
fi

# Build image with both tags
if [ -n "${PROFILE}" ]; then
    log_info "Building profile image ${REPO}/${IMAGE_NAME} (profile=${PROFILE}) with tags: ${TAG1}, ${TAG2}"
else
    log_info "Building image ${REPO}/${IMAGE_NAME} with tags: ${TAG1}, ${TAG2}"
fi
BUILD_TAG_FLAGS=()
# If a profile build is requested, prefix tags with the profile to avoid collisions
if [ -n "${PROFILE}" ]; then
    # Create a human-friendly profile slug by stripping leading numeric prefixes like "20-00-"
    PROFILE_SLUG=$(echo "${PROFILE}" | sed -E 's/^[0-9]+(-[0-9]+)*-//')
    for t in "${TAGS_LIST[@]}"; do
        BUILD_TAG_FLAGS+=("-t" "${REPO}/${IMAGE_NAME}:${PROFILE_SLUG}-${t}")
    done
else
    for t in "${TAGS_LIST[@]}"; do
        BUILD_TAG_FLAGS+=("-t" "${REPO}/${IMAGE_NAME}:${t}")
    done
fi

BUILDX_CMD=(docker buildx build)
BUILDX_CMD+=("${BUILD_ARGS[@]}")
BUILDX_CMD+=(--build-arg "GIT_SHA=${GIT_SHA}")
BUILDX_CMD+=(--build-arg "BUILD_DATE=$(date -u +'%Y-%m-%dT%H:%M:%SZ')")
BUILDX_CMD+=(--label "org.opencontainers.image.created=$(date -u +'%Y-%m-%dT%H:%M:%SZ')")
BUILDX_CMD+=(--label "org.opencontainers.image.version=${TAG1}")
BUILDX_CMD+=(--label "org.opencontainers.image.revision=${GIT_SHA}")
BUILDX_CMD+=(-f "${DOCKERFILE}")
BUILDX_CMD+=(--progress=${PROGRESS})
BUILDX_CMD+=("${BUILD_TAG_FLAGS[@]}")
BUILDX_CMD+=("$@")
# If a specific profile was requested, build only that final-stage target
if [ -n "${PROFILE}" ]; then
    BUILDX_CMD+=(--target "final-${PROFILE}")
fi
BUILDX_CMD+=(.)

if [ "${DRY_RUN}" = true ]; then
    log_info "Dry run: printing the buildx command (not executed)"
    printf '%s ' "${BUILDX_CMD[@]}"
    echo
else
    "${BUILDX_CMD[@]}"
fi

# Attempt to determine the resulting image digest for CI/promotion workflows.
# We prefer to read the digest via `docker buildx imagetools inspect` (works for registry refs)
# and fall back to the local image RepoDigests when available.
PRIMARY_TAG=""
if [ -n "${PROFILE:-}" ]; then
    # PROFILE_SLUG may have been computed earlier; recompute guardingly
    PROFILE_SLUG=${PROFILE_SLUG:-$(echo "${PROFILE}" | sed -E 's/^[0-9]+(-[0-9]+)*-//')}
    PRIMARY_TAG="${REPO}/${IMAGE_NAME}:${PROFILE_SLUG}-${TAGS_LIST[0]}"
else
    PRIMARY_TAG="${REPO}/${IMAGE_NAME}:${TAGS_LIST[0]}"
fi

IMAGE_DIGEST=""
if command -v docker >/dev/null 2>&1; then
    # Try imagetools inspect first (works when the tag is pushed or present in registry)
    if docker buildx imagetools inspect "${PRIMARY_TAG}" >/dev/null 2>&1; then
        IMAGE_DIGEST=$(docker buildx imagetools inspect "${PRIMARY_TAG}" 2>/dev/null | awk -F': ' '/Digest:/ {print $2; exit}') || true
    fi

    # Fallback: try to read RepoDigests from local image store
    if [ -z "${IMAGE_DIGEST}" ]; then
        repo_digest=$(docker image inspect "${PRIMARY_TAG}" --format '{{index .RepoDigests 0}}' 2>/dev/null || true)
        if [ -n "${repo_digest}" ]; then
            IMAGE_DIGEST=${repo_digest#*@}
        fi
    fi
fi

if [ -n "${IMAGE_DIGEST}" ]; then
    echo "${IMAGE_DIGEST}" > image-digest.txt
    export IMAGE_DIGEST
    log_info "Image digest: ${IMAGE_DIGEST} (saved to image-digest.txt)"
else
    log_warn "Could not determine image digest. If you need an immutable digest, run with --push or inspect the registry after pushing."
fi

# Print a helpful run command now that the build finished
if [ "${DRY_RUN}" != true ]; then
    if [ -n "${PRIMARY_TAG}" ]; then
        if [ "${PUSH}" = "true" ]; then
            echo ""
            echo "Image pushed as: ${PRIMARY_TAG}"
            echo "To run locally: docker pull ${PRIMARY_TAG} && docker run -it --rm -u jovyan -w /home/jovyan ${PRIMARY_TAG} zsh"
            echo ""
        else
            # If the build used --load (or single-platform default), image should be available locally
            if [[ " ${BUILD_ARGS[*]} " == *"--load"* ]] || [ "${LOAD}" = true ]; then
                echo ""
                echo "Image loaded locally as: ${PRIMARY_TAG}"
                echo "To run: docker run -it --rm -u jovyan -w /home/jovyan ${PRIMARY_TAG} zsh"
                echo ""
            else
                echo ""
                echo "Image built but not loaded locally (multi-platform or output driver used)."
                echo "To run locally, rebuild for your host or pull the pushed image. Example:"
                echo "  docker build --target final-${PROFILE} -t ${PRIMARY_TAG} -f Dockerfile.generated . && docker run -it --rm -u jovyan -w /home/jovyan ${PRIMARY_TAG} zsh"
                echo ""
            fi
        fi
    fi
fi

# Emit a structured build artifact for CI consumption
BUILD_ARTIFACT_FILE=${BUILD_ARTIFACT_FILE:-build-artifact.json}
profile_name=""
profile_slug_json=""
if [ -n "${PROFILE:-}" ]; then
    profile_name="${PROFILE}"
    PROFILE_SLUG=${PROFILE_SLUG:-$(echo "${PROFILE}" | sed -E 's/^[0-9]+(-[0-9]+)*-//')}
    profile_slug_json="${PROFILE_SLUG}"
fi

# Build full tag list as applied to the image
TAGS_JSON=""
for t in "${TAGS_LIST[@]}"; do
    if [ -n "${PROFILE}" ]; then
        full_tag="${REPO}/${IMAGE_NAME}:${PROFILE_SLUG}-${t}"
    else
        full_tag="${REPO}/${IMAGE_NAME}:${t}"
    fi
    # escape double quotes just in case (tags shouldn't contain quotes)
    full_tag_escaped=$(printf '%s' "$full_tag" | sed 's/"/\\"/g')
    TAGS_JSON+="\"${full_tag_escaped}\","
done
# strip trailing comma
TAGS_JSON="${TAGS_JSON%,}"

IMAGE_BY_DIGEST=""
if [ -n "${IMAGE_DIGEST}" ]; then
    IMAGE_BY_DIGEST="${REPO}/${IMAGE_NAME}@${IMAGE_DIGEST}"
fi

# compose JSON
cat > "${BUILD_ARTIFACT_FILE}" <<JSON
{
  "repository": "${REPO}",
  "image_name": "${IMAGE_NAME}",
  "profile": "${profile_name}",
  "profile_slug": "${profile_slug_json}",
  "tags": [${TAGS_JSON}],
  "digest": "${IMAGE_DIGEST}",
  "image_by_digest": "${IMAGE_BY_DIGEST}",
  "git": {
    "branch": "${GIT_BRANCH}",
    "sha": "${GIT_SHA_SHORT}",
    "full_sha": "${FULL_GIT_SHA}"
  },
  "created": "${BUILD_DATE_UTC}"
}
JSON

log_info "Wrote build artifact: ${BUILD_ARTIFACT_FILE}"

# Optionally build a codeserver image that uses the just-built image as its base.
if [[ "${BUILD_CODESERVER}" == "true" ]]; then
        CODESERVER_TAG="${REPO}/${IMAGE_NAME}:${TAG1}-codeserver"
        BASE_IMAGE_TAG="${REPO}/${IMAGE_NAME}:${TAG1}"
        log_info "Building codeserver image ${CODESERVER_TAG} using base ${BASE_IMAGE_TAG}"
        DOCKER_BUILDKIT=1 docker build -t "${CODESERVER_TAG}" \
            --build-arg BASE_IMAGE="${BASE_IMAGE_TAG}" \
            -f Dockerfile.codeserver .
fi

# Push if requested
if [[ "${PUSH}" == "true" ]]; then
    if check_git_state; then
        log_info "Pushing image ${REPO}/${IMAGE_NAME}:${TAG1}"
        docker push "${REPO}/${IMAGE_NAME}:${TAG1}"
        log_info "Pushing image ${REPO}/${IMAGE_NAME}:${TAG2}"
        docker push "${REPO}/${IMAGE_NAME}:${TAG2}"
        if [[ "${BUILD_CODESERVER}" == "true" ]]; then
            log_info "Pushing codeserver image ${CODESERVER_TAG}"
            docker push "${CODESERVER_TAG}"
        fi
    else
        log_error "Cannot push: uncommitted changes detected"
        exit 1
    fi
fi

log_info "Build completed successfully"
