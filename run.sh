#!/usr/bin/env bash
set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
NC='\033[0m'

# Export environment variables
export IMAGE_REPO=${IMAGE_REPO:-brunoe}
export TAG=$(git rev-parse --abbrev-ref HEAD | tr '/' '-')
export SSH_DIR=${SSH_DIR:-$HOME/.ssh}

# Start container
echo -e "${GREEN}Starting Jupyter environment...${NC}"
if [ $# -eq 0 ]; then
    # No arguments, start normally
    docker compose up
else
    # Pass arguments to the container
    docker compose run --rm jupyter "$@"
fi