#!/usr/bin/env bash
set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
NC='\033[0m'

# Export environment variables
export IMAGE_REPO=${IMAGE_REPO:-ghcr.io/ebpro}
export TAG=$(git rev-parse --abbrev-ref HEAD | tr '/' '-')
export SSH_DIR=${SSH_DIR:-$HOME/.ssh}

# Start container
echo -e "${GREEN}Starting Jupyter environment...${NC}"

# Determine container runtime: prefer user-provided, then podman, then docker
CONTAINER_RUNTIME=${CONTAINER_RUNTIME:-}
if [ -z "${CONTAINER_RUNTIME}" ]; then
    if command -v podman >/dev/null 2>&1; then
        CONTAINER_RUNTIME=podman
    else
        CONTAINER_RUNTIME=docker
    fi
fi

COMPOSE_CMD=""
if [ "${CONTAINER_RUNTIME}" = "podman" ]; then
    # Prefer the built-in `podman compose` if available, otherwise fall back to podman-compose
    if podman compose version >/dev/null 2>&1; then
        COMPOSE_CMD="podman compose"
    elif command -v podman-compose >/dev/null 2>&1; then
        COMPOSE_CMD="podman-compose"
    else
        echo -e "${YELLOW}WARN: podman found but no compose implementation available; expected 'podman compose' or 'podman-compose'. Falling back to docker if available.${NC}"
        if command -v docker >/dev/null 2>&1; then
            CONTAINER_RUNTIME=docker
            COMPOSE_CMD="docker compose"
        else
            echo -e "${RED}ERROR: No container runtime with compose support found.${NC}" >&2
            exit 1
        fi
    fi
else
    COMPOSE_CMD="docker compose"
fi

if [ $# -eq 0 ]; then
    # No arguments, start normally
    ${COMPOSE_CMD} up
else
    # Pass arguments to the container
    ${COMPOSE_CMD} run --rm jupyter "$@"
fi
