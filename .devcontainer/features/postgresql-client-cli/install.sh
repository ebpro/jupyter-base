# Auto-inserted by scripts/inject_prebaked_helpers.sh
# Source shared feature helpers (prebaked into image) or fall back to repository helper
if [ -n "${FEATURE_HELPERS_DIR:-}" ] && [ -f "${FEATURE_HELPERS_DIR}/helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "${FEATURE_HELPERS_DIR}/helpers.sh"
elif [ -f "../../../scripts/feature_helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "../../../scripts/feature_helpers.sh"
fi
#!/usr/bin/env bash
set -euo pipefail

echo "===================================================================="
echo "Feature: PostgreSQL Enhanced CLI (pgcli)"
echo "===================================================================="

# Install pgcli via pip
echo "📦 Installing pgcli (enhanced PostgreSQL CLI)..."

# Prefer conda pip if available (avoids PEP 668 externally-managed-environment)
if [ -n "${CONDA_DIR:-}" ] && [ -f "${CONDA_DIR}/bin/pip" ]; then
    "${CONDA_DIR}/bin/pip" install pgcli || true
elif command -v pip3 >/dev/null 2>&1; then
    NB_USER=${NB_USER:-jovyan}
    NB_UID=${NB_UID:-1001}
    NB_GID=${NB_GID:-1001}
    HOME_DIR="/home/${NB_USER}"
    mkdir -p "${HOME_DIR}/.cache/pip" 2>/dev/null || true
    chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/.cache" 2>/dev/null || true
    TMP_SCRIPT="/tmp/install-pgcli-${NB_USER}.sh"
    cat > "${TMP_SCRIPT}" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
python3 -m pip install --break-system-packages pgcli || true
BASH
    chmod +x "${TMP_SCRIPT}"
    su - ${NB_USER:-jovyan} -s /bin/bash -c "${TMP_SCRIPT}" || true
    rm -f "${TMP_SCRIPT}"
elif command -v pip >/dev/null 2>&1; then
    NB_USER=${NB_USER:-jovyan}
    NB_UID=${NB_UID:-1001}
    NB_GID=${NB_GID:-1001}
    HOME_DIR="/home/${NB_USER}"
    mkdir -p "${HOME_DIR}/.cache/pip" 2>/dev/null || true
    chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/.cache" 2>/dev/null || true
    TMP_SCRIPT="/tmp/install-pgcli-${NB_USER}.sh"
    cat > "${TMP_SCRIPT}" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
python -m pip install --break-system-packages pgcli || true
BASH
    chmod +x "${TMP_SCRIPT}"
    su - ${NB_USER:-jovyan} -s /bin/bash -c "${TMP_SCRIPT}" || true
    rm -f "${TMP_SCRIPT}"
else
    echo "⚠️  Python/pip not available, falling back to apt"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends pgcli
fi

# Create pgcli configuration directory
NB_USER=${NB_USER:-jovyan}
HOME_DIR="/home/${NB_USER}"

mkdir -p "${HOME_DIR}/.config/pgcli"

cat > "${HOME_DIR}/.config/pgcli/config" << 'EOF'
[main]
# Multi-line mode allows breaking up the sql statements into multiple lines
multi_line = True

# Auto-completion while typing
auto_expand = True

# Enables context-sensitive auto-completion
smart_completion = True

# Show/hide the informational toolbar
show_bottom_toolbar = True

# Syntax highlighting
syntax_style = default

# Number of lines to show in the suggestion menu
suggestion_width = 75

# Character used for the query history file
history_file = ~/.pgcli-history

# log_file location
log_file = ~/.pgcli.log

# Default log level
log_level = INFO

# Timing of sql statements
timing = True

# Table format
table_format = psql

# Syntax style
syntax_style = default

# Wider completion menus
wider_completion_menu = True

# Expand mode (auto, always, never)
expand = auto
EOF

chown -R ${NB_UID:-1001}:${NB_GID:-1001} "${HOME_DIR}/.config" 2>/dev/null || true

# Verify installation
echo ""
echo "✅ Verifying pgcli installation..."
# Source conda to get pgcli in PATH, or check if it exists in conda bin
if [ -f "${HOME_DIR}/miniforge3/etc/profile.d/conda.sh" ]; then
  source "${HOME_DIR}/miniforge3/etc/profile.d/conda.sh" 2>/dev/null || true
  conda activate base 2>/dev/null || true
fi
if command -v pgcli >/dev/null 2>&1; then
  pgcli --version
else
  echo "pgcli installed but not yet in PATH (will be available after sourcing conda)"
fi

echo ""
echo "✅ pgcli installed successfully!"
echo ""
echo "pgcli features:"
echo "  - Smart autocomplete (context-aware)"
echo "  - Syntax highlighting"
echo "  - Multi-line queries"
echo "  - Query history"
echo "  - Vi/Emacs key bindings"
echo ""
echo "Example usage:"
echo "  pgcli postgresql://user:password@localhost:5432/database"
echo "  pgcli -h localhost -U postgres -d mydb"
echo ""
echo "Useful pgcli commands:"
echo "  \\dt              - List tables"
echo "  \\d table_name    - Describe table"
echo "  \\timing          - Toggle query timing"
echo "  \\e               - Edit query in editor"
echo "  \\q               - Quit"
echo "===================================================================="
