#!/usr/bin/env sh

# Require sourcing: detect whether this file is being sourced or executed.
(return 0 2>/dev/null) && _SOURCED=1 || _SOURCED=0

die() {
    printf '%s\n' "$1" >&2
    if [ "$_SOURCED" -eq 1 ]; then
        return 1
    else
        exit 1
    fi
}

# Default values (only set if not already defined in the environment)
NB_USER=${NB_USER:-jovyan}
WORK_DIR=${WORK_DIR:-/home/${NB_USER}/work}
COURSE_DIR=${COURSE_DIR:-${WORK_DIR}/course}
EXAMPLES_DIR=${EXAMPLES_DIR:-${WORK_DIR}/examples}
ASSIGNMENTS_DIR=${ASSIGNMENTS_DIR:-${WORK_DIR}/assignments}
DATA_DIR=${DATA_DIR:-${WORK_DIR}/data}

# Positional parameters when sourcing: provider, repo, branch
PROVIDER=${1:-github}
REPO=${2:-}
BRANCH=${3:-develop}

if [ -z "$REPO" ]; then
        die "Usage: source get_src_dir.sh [provider] repo [branch]"
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
export PROVIDER_SRC_DIR="${EXAMPLES_DIR}/${PROVIDER}"
export SRC_DIR="${PROVIDER_SRC_DIR}/${REPO}"
