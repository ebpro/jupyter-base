#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

# Color definitions for console output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Logging helpers
log() { printf "%b[INFO]%b %s\n" "${GREEN}" "${NC}" "$1" >&2; }
error() { printf "%b[ERROR]%b %s\n" "${RED}" "${NC}" "$1" >&2; exit 1; }
warn() { printf "%b[WARNING]%b %s\n" "${YELLOW}" "${NC}" "$1" >&2; }
info() { printf "%b[INFO]%b %s\n" "${BLUE}" "${NC}" "$1" >&2; }

# Help function
show_help() {
    cat << EOF
Usage: $(basename "$0") [options] REPO

Clone or update a Git repository with Markdown output.

Options:
    -h, --help              Show this help message
    -m, --message TEXT      Custom message to include before the output
    -p, --provider STRING   Git provider (github|gitlab|bitbucket) [default: github]
    -b, --branch STRING     Branch to clone [default: develop]
    -d, --dir STRING        Base directory for repositories [default: \${EXAMPLES_DIR:-\$HOME/work}]
    -q, --quiet             Suppress console output
    --no-markdown           Skip markdown output, only log to console

Arguments:
    REPO                    Repository in format: owner/repo-name

Examples:
    $(basename "$0") -p github -b main ebpro/my-repo
    $(basename "$0") --message "Project source:" microsoft/vscode
    $(basename "$0") -d /opt/repos -b develop user/project

EOF
}

# Function for Markdown output
output_markdown() {
    local result_status=$1
    local action=$2
    local commit_hash commit_msg commit_info

    # Get commit information if available
    if [ -d "${SRC_DIR}/.git" ]; then
        commit_hash=$(git -C "${SRC_DIR}" log -1 --pretty=format:'%h' 2>/dev/null || echo 'unknown')
        commit_msg=$(git -C "${SRC_DIR}" log -1 --pretty=format:'%s' 2>/dev/null || echo 'No commit info')
        commit_info="${commit_hash} - ${commit_msg}"
    else
        commit_info="No commit information available"
    fi

    local when
    when=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Determine emoji based on status
    local emoji status_text
    if [ "$result_status" -eq 0 ]; then
        emoji="✅"
        status_text=""
    else
        emoji="❌"
        status_text=""
    fi

    # Output custom message if provided
    if [ -n "${MESSAGE}" ]; then
        printf "%s\n\n" "${MESSAGE}"
    fi

    # Concise single-line summary
    printf "%s %s: [%s](%s)\n\n" "$emoji" "$status_text" "$REPO" "$REPO_URL"

    # Collapsible details with more information
    cat << 'MARKDOWN'
<details>
<summary>Détails</summary>

MARKDOWN
    printf -- "\n"
    printf -- "- **URL**: %s\n" "${REPO_URL}"
    printf -- "- **Branch**: %s\n" "${BRANCH}"
    printf -- "- **Local Path**: \`%s\`\n" "${SRC_DIR}"
    printf -- "- **Latest Commit**: %s\n" "${commit_info}"
    printf -- "- **Timestamp**: %s\n\n" "${when}"

    printf "**Clone Command:**\n"
    printf '```bash\n'
    printf 'git clone -b %s %s\n' "${BRANCH}" "${REPO_URL}"
    printf '```\n\n'

    printf '</details>\n\n'
}

# Validate repository format
validate_repo() {
    if [[ ! "$1" =~ ^[a-zA-Z0-9_-]+/[a-zA-Z0-9._-]+$ ]]; then
        error "Invalid repository format. Expected: owner/repo-name, got: $1"
    fi
}

# Check if git is installed
check_dependencies() {
    if ! command -v git >/dev/null 2>&1; then
        error "Git is not installed. Please install git first."
    fi
}

# Default values
PROVIDER="github"
BRANCH="develop"
QUIET=0
MESSAGE=""
OUTPUT_MARKDOWN=1

# Default examples dir (only if not set in environment)
EXAMPLES_DIR=${EXAMPLES_DIR:-"$HOME/work"}

# Parse arguments
POSITIONAL_ARGS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -p|--provider)
            if [ -z "${2:-}" ]; then
                error "Option $1 requires an argument"
            fi
            PROVIDER="$2"
            shift 2
            ;;
        -m|--message)
            if [ -z "${2:-}" ]; then
                error "Option $1 requires an argument"
            fi
            MESSAGE="$2"
            shift 2
            ;;
        -b|--branch)
            if [ -z "${2:-}" ]; then
                error "Option $1 requires an argument"
            fi
            BRANCH="$2"
            shift 2
            ;;
        -d|--dir)
            if [ -z "${2:-}" ]; then
                error "Option $1 requires an argument"
            fi
            EXAMPLES_DIR="$2"
            shift 2
            ;;
        -q|--quiet)
            QUIET=1
            shift
            ;;
        --no-markdown)
            OUTPUT_MARKDOWN=0
            shift
            ;;
        --)
            shift
            break
            ;;
        -*)
            show_help
            error "Unknown option: $1"
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done

# Restore positional arguments
set -- "${POSITIONAL_ARGS[@]}"

# Validate required parameter
if [ "$#" -eq 0 ]; then
    show_help
    error "Repository parameter is required"
fi

REPO="$1"

# Run validation checks
check_dependencies
validate_repo "${REPO}"

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
        error "Unsupported provider: ${PROVIDER}. Supported: github, gitlab, bitbucket"
        ;;
esac

# Set paths
REPO_URL="${BASE_URL}/${REPO}"
PROVIDER_SRC_DIR="${EXAMPLES_DIR}/${PROVIDER}"
export SRC_DIR="${PROVIDER_SRC_DIR}/${REPO}"

# Create directories
[ "$QUIET" -eq 0 ] && info "Target directory: ${SRC_DIR}"
mkdir -p "${PROVIDER_SRC_DIR}" || error "Failed to create directory ${PROVIDER_SRC_DIR}"

# Clone/update repository
STATUS=0
ACTION=""

if [ -d "${SRC_DIR}/.git" ]; then
    # Repository exists - update it
    [ "$QUIET" -eq 0 ] && log "Updating existing repository in ${SRC_DIR}"

    if command -v gitpuller >/dev/null 2>&1; then
        # Use gitpuller if available (for JupyterHub environments)
        gitpuller "${REPO_URL}" "${BRANCH}" "${SRC_DIR}" >/dev/null 2>&1 || STATUS=$?
    else
        # Standard git update workflow
        {
            git -C "${SRC_DIR}" fetch --all --prune &&
            git -C "${SRC_DIR}" checkout "${BRANCH}" &&
            git -C "${SRC_DIR}" pull origin "${BRANCH}"
        } >/dev/null 2>&1 || STATUS=$?
    fi

    ACTION="Updated existing repository"
    [ "$QUIET" -eq 0 ] && [ "$STATUS" -eq 0 ] && log "Repository updated successfully"
else
    # Repository doesn't exist - clone it
    [ "$QUIET" -eq 0 ] && log "Cloning new repository to ${SRC_DIR}"

    git clone -b "${BRANCH}" "${REPO_URL}" "${SRC_DIR}" >/dev/null 2>&1 || STATUS=$?

    ACTION="Cloned new repository"
    [ "$QUIET" -eq 0 ] && [ "$STATUS" -eq 0 ] && log "Repository cloned successfully"
fi

# Check for errors
if [ "$STATUS" -ne 0 ]; then
    warn "Git operation failed with status code: ${STATUS}"
fi

# Output markdown (unless disabled)
if [ "$OUTPUT_MARKDOWN" -eq 1 ]; then
    output_markdown "$STATUS" "${ACTION}"
fi

exit "$STATUS"
