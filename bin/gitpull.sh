#!/bin/zsh

# Color definitions for console output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Functions
log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" >&2 }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1 }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1" >&2 }

# Help function
show_help() {
    cat << EOF
Usage: $(basename $0) [options] REPO
Clone or update a Git repository with Markdown output.

Options:
    -h, --help              Show this help message
    -m, --message           A paragraph of text to include before the output
    -p, --provider STRING   Git provider (github|gitlab|bitbucket) [default: github]
    -b, --branch STRING     Branch to clone [default: develop]
    -d, --dir STRING       Base directory for repositories [default: $MATERIALS_DIR] 
    -q, --quiet            Suppress console output

Example:
    $(basename $0) -p github -b main ebpro/my-repo
EOF
}

# Function for Markdown output
output_markdown() {
    local result_status=$1
    local action=$2
    local commit_info=$(cd "${SRC_DIR}" 2>/dev/null && git log -1 --format="reference" || echo "No commit info")
    local emoji=$([[ $result_status == 0 ]] && echo "✅" || echo "❌")
    
    cat << EOF

${MESSAGE}

- **Source**: [${REPO}](${REPO_URL})
- **Branch**: \`${BRANCH}\`
- **Latest Commit**: \`${commit_info}\`
- **Cloned to**: \$\{SRC_DIR\}\=\`${SRC_DIR}\`

To get it:

\`\`\`bash
git clone -b ${BRANCH} ${REPO_URL}
\`\`\`
EOF
}

# Default values
PROVIDER="github"
BRANCH="develop"
QUIET=1
MESSAGE="Le code suivant est accessible dans l'entrepôt suivant :"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -p|--provider)
            PROVIDER="$2"
            shift 2
            ;;
        -m|--message)
            MESSAGE="$2"
            shift 2
            ;;
        -b|--branch)
            BRANCH="$2"
            shift 2
            ;;
        -d|--dir)
            MATERIALS_DIR="$2"
            shift 2
            ;;
        -q|--quiet)
            QUIET=1
            shift
            ;;
        *)
            REPO="$1"
            shift
            ;;
    esac
done

# Validate required parameter
if [ -z "$REPO" ]; then
    show_help
    error "Repository parameter is required"
fi

# Configure provider URLs
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
        error "Unsupported provider: ${PROVIDER}"
        ;;
esac

# Set paths
REPO_URL="${BASE_URL}/${REPO}"
PROVIDER_SRC_DIR="${MATERIALS_DIR}/${PROVIDER}"
export SRC_DIR="${PROVIDER_SRC_DIR}/${REPO}"

# Create directories
mkdir -p "${PROVIDER_SRC_DIR}" || error "Failed to create directory ${PROVIDER_SRC_DIR}"

# Clone/update repository
STATUS=0
if [ -d "${SRC_DIR}/.git" ]; then
    [ $QUIET -eq 0 ] && log "Updating existing repository in ${SRC_DIR}"
    gitpuller ${REPO_URL} "${BRANCH}" "${SRC_DIR}" >/dev/null 2>&1 || STATUS=$?
    ACTION="Updated existing repository"
else
    [ $QUIET -eq 0 ] && log "Cloning new repository to ${SRC_DIR}"
    git clone -b "${BRANCH}" "${REPO_URL}" "${SRC_DIR}" >/dev/null 2>&1 || STATUS=$?
    ACTION="Cloned new repository"
fi

# Output markdown
output_markdown $STATUS "${ACTION}"

exit $STATUS