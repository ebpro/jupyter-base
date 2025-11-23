#!/bin/bash
set -euo pipefail

# Archived: versions/generators/base-jupyter.sh
# Kept for reference; this script generated Jupyter-related info for older workflows.

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echoerr() { echo "$@" 1>&2; }

# Logging functions
log_info() { echoerr -e "${GREEN}INFO: $1${NC}"; }
log_warn() { echoerr -e "${YELLOW}WARN: $1${NC}"; }
log_error() { echoerr -e "${RED}ERROR: $1${NC}" >&2; }

# Check Jupyter availability
check_jupyter() {
    if ! command -v jupyter &> /dev/null; then
        log_error "Jupyter is not installed"
        return 1
    fi
    return 0
}

# Generate Jupyter information
generate_jupyter_info() {
        echo "## Jupyter Environment"
        echo
        echo "Generated on: $(date '+%Y-%m-%d %H:%M:%S')"
        echo
        
        echo "### Jupyter Lab Extensions"
        echo
        echo "```"
        jupyter labextension list 2>/dev/null || echo "No extensions installed"
        echo "```"
        echo
        
        echo "### Jupyter Kernels"
        echo
        echo "```"
        jupyter kernelspec list 2>/dev/null || echo "No kernels installed"
        echo "```"
        echo
        
        echo "### Python Packages"
        echo
        echo "| Package | Version |"
        echo "|---------|:--------|"
        pip list --format=json 2>/dev/null | \
            jq -r '.[] | "| \(.name) | \(.version) |"' | \
            sort
}

# Main execution
main() {
    if ! check_jupyter; then
        exit 1
    fi

    generate_jupyter_info
}

# Run main function
main
