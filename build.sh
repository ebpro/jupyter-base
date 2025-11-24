#!/bin/bash
set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

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
    local git_tag=$(get_git_tag)
    local git_sha=$(get_git_sha)
    local git_branch=$(get_git_branch)
    
    if [[ -n "${git_tag}" ]]; then
        # For tags, use tag and tag-sha
        echo "${git_tag} ${git_tag}-${git_sha}"
    elif [[ "${git_branch}" == "main" || "${git_branch}" == "master" ]]; then
        # For main/master, use latest and branch-sha
        echo "latest ${git_branch}-${git_sha}"
    else
        # For feature branches, use branch and branch-sha
        echo "${git_branch} ${git_branch}-${git_sha}"
    fi
}

# Platform detection functions
detect_build_platform() {
    echo "linux/$(uname -m)"
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
REPO=${REPO:-$(docker info 2>/dev/null | grep Username |tr -d ' '| cut -d':' -f2 || echo "brunoe")}
IMAGE_NAME=${PWD##*/}
read -r TAG1 TAG2 <<< "$(get_version_tags)"
GIT_SHA=$(get_git_sha)
BUILD_PLATFORM=$(detect_build_platform)
TARGET_PLATFORM=${PLATFORM:-${BUILD_PLATFORM}}

# Logging functions
log_info() { echo -e "${GREEN}INFO: $1${NC}"; }
log_warn() { echo -e "${YELLOW}WARN: $1${NC}"; }
log_error() { echo -e "${RED}ERROR: $1${NC}" >&2; }

# Help message
show_help() {
    cat << EOF
Usage: $(basename "$0") [options]

Build Docker image with specified options.

Options:
    -h, --help          Show this help message
    -r, --repo          Docker repository name (default: ${REPO})
    -t, --tag           Custom tag (default: ${TAG1})
    -p, --platform      Build platform (default: ${TARGET_PLATFORM})
    --push              Push image after build
    --build-codeserver  Build a codeserver image based on the built image and `Dockerfile.codeserver`
    --load              Attempt to load multi-platform images locally (may not work with all platforms)

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
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) show_help; exit 0 ;;
        -r|--repo) REPO="$2"; shift 2 ;;
        -t|--tag) TAG1="$2" TAG2="${2}-${GIT_SHA}"; shift 2 ;;
        -p|--platform) TARGET_PLATFORM="$2"; shift 2 ;;
        --push) PUSH=true; shift ;;
        --build-codeserver|--codeserver) BUILD_CODESERVER=true; shift ;;
        --load) LOAD=true; shift ;;
        *) break ;;
    esac
done

# Check Git state before building
check_git_state || log_warn "Consider committing changes before building"

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
log_info "Building image ${REPO}/${IMAGE_NAME} with tags: ${TAG1}, ${TAG2}"
docker buildx build \
    "${BUILD_ARGS[@]}" \
    --build-arg GIT_SHA="${GIT_SHA}" \
    --build-arg BUILD_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --label org.opencontainers.image.created="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --label org.opencontainers.image.version="${TAG1}" \
    --label org.opencontainers.image.revision="${GIT_SHA}" \
    --progress=plain \
    -t "${REPO}/${IMAGE_NAME}:${TAG1}" \
    -t "${REPO}/${IMAGE_NAME}:${TAG2}" \
    "$@" \
    .

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