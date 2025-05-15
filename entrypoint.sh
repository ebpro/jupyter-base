#!/bin/zsh
set -euo pipefail

# Source startup scripts
if [[ -f /usr/local/bin/run-startup-scripts.sh ]]; then
    source /usr/local/bin/run-startup-scripts.sh
fi

# Execute the command
exec "$@"