#!/bin/zsh

# Default values
MATERIALS_DIR=${MATERIALS_DIR:-"/home/jovyan/work/materials"}
PROVIDER=${1:-"github"}
REPO=${2:-""}
BRANCH=${3:-"develop"}

if [[ -z "$REPO" ]]; then
    echo "Usage: source $(basename $0) [provider] repo [branch]" >&2
    return 1
fi

# Configure provider URL
case ${PROVIDER} in
    "github")
        BASE_URL="https://github.com"
        ;;
    "gitlab")
        BASE_URL="https://gitlab.com"
        ;;
    "bitbucket")
        BASE_URL="https://bitbucket.org"
        ;;
    *)
        echo "Error: Unsupported provider: ${PROVIDER}" >&2
        return 1
        ;;
esac

# Export variables
export REPO_URL="${BASE_URL}/${REPO}"
export PROVIDER_SRC_DIR="${MATERIALS_DIR}/${PROVIDER}"
export SRC_DIR="${PROVIDER_SRC_DIR}/${REPO}"
