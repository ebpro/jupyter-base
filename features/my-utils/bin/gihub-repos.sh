#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Help function
show_help() {
    cat << EOF
Usage: $(basename "$0") <github_username> <repo_pattern> [options]

Arguments:
    github_username    GitHub username to fetch repositories from
    repo_pattern      Pattern to filter repository names (supports regex)

Options:
    -t, --token       GitHub token (or set GITHUB_TOKEN env var)
    -l, --limit       Maximum number of repositories to fetch (default: all)
    -s, --sort        Sort by: updated, created, pushed (default: updated)
    -h, --help        Show this help message

Example:
    $(basename "$0") octocat "sample-" -s updated -l 10
EOF
}

# Parse arguments
parse_args() {
    GITHUB_USER=""
    REPO_PATTERN=""
    SORT_BY="updated"
    LIMIT=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help) show_help; exit 0 ;;
            -t|--token) GITHUB_TOKEN="$2"; shift 2 ;;
            -s|--sort) SORT_BY="$2"; shift 2 ;;
            -l|--limit) LIMIT="$2"; shift 2 ;;
            *)
                if [ -z "$GITHUB_USER" ]; then
                    GITHUB_USER="$1"
                elif [ -z "$REPO_PATTERN" ]; then
                    REPO_PATTERN="$1"
                else
                    echo -e "${RED}Error: Unexpected argument '$1'${NC}" >&2
                    show_help
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Validate required arguments
    if [ -z "$GITHUB_USER" ] || [ -z "$REPO_PATTERN" ]; then
        echo -e "${RED}Error: Missing required arguments${NC}" >&2
        show_help
        exit 1
    fi
}

# Function to fetch repositories with pagination
fetch_repos() {
    local page=1
    local count=0
    local has_more=true

    while $has_more; do
        local api_url="https://api.github.com/users/$GITHUB_USER/repos"
        api_url+="?page=${page}&per_page=100&sort=${SORT_BY}"
        
        local headers=""
        if [ -n "${GITHUB_TOKEN:-}" ]; then
            headers="-H \"Authorization: Bearer $GITHUB_TOKEN\""
        fi

        # Fetch repositories
        local response
        response=$(curl -s -w '%{http_code}' $headers "$api_url")
        local status_code=${response: -3}
        local body=${response:0:${#response}-3}

        # Check for errors
        if [ "$status_code" != "200" ]; then
            echo -e "${RED}Error: GitHub API returned status $status_code${NC}" >&2
            echo "$body" >&2
            exit 1
        fi

        # Process results
        local repos
        repos=$(echo "$body" | jq -r --arg pattern "$REPO_PATTERN" \
            '.[] | select(.name | match($pattern; "i")) | 
            "| [\(.name)](\(.html_url)) | \(.description // \"No description\") | \(.language // \"N/A\") | \(.updated_at[0:10]) |"')

        if [ -n "$repos" ]; then
            echo "$repos"
            count=$((count + $(echo "$repos" | wc -l)))
        fi

        # Check if we should continue
        if [ -n "$LIMIT" ] && [ "$count" -ge "$LIMIT" ]; then
            has_more=false
        elif [ "$(echo "$body" | jq '. | length')" -lt 100 ]; then
            has_more=false
        else
            page=$((page + 1))
        fi
    done
}

# Main execution
main() {
    parse_args "$@"

    echo "| Repository | Description | Language | Last Updated |"
    echo "|------------|-------------|----------|--------------|"
    
    if ! fetch_repos; then
        echo -e "${RED}Error: Failed to fetch repositories${NC}" >&2
        exit 1
    fi
}

main "$@"
