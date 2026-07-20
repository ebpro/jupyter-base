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
echo "Feature: MySQL Enhanced CLI (mycli)"
echo "===================================================================="

# Ensure notebook user variables
NB_USER=${NB_USER:-jovyan}
NB_UID=${NB_UID:-1001}
NB_GID=${NB_GID:-1001}
HOME_DIR="/home/${NB_USER}"

# Ensure pip cache owned by notebook user to avoid warnings
mkdir -p "${HOME_DIR}/.cache/pip" 2>/dev/null || true
chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/.cache" 2>/dev/null || true

echo "📦 Installing mycli (enhanced MySQL/MariaDB CLI)..."

# Prefer conda pip when available, otherwise install as the notebook user so cache is used
if [ -n "${CONDA_DIR:-}" ] && [ -f "${CONDA_DIR}/bin/pip" ]; then
    "${CONDA_DIR}/bin/pip" install mycli || true
elif command -v pip3 >/dev/null 2>&1; then
    # Run pip as NB_USER to use user's pip cache
    TMP_SCRIPT="/tmp/install-mycli-${NB_USER}.sh"
    cat > "${TMP_SCRIPT}" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
python3 -m pip install mycli || true
BASH
    chmod +x "${TMP_SCRIPT}"
    su - ${NB_USER:-jovyan} -s /bin/bash -c "${TMP_SCRIPT}" || true
    rm -f "${TMP_SCRIPT}"
elif command -v pip >/dev/null 2>&1; then
    TMP_SCRIPT="/tmp/install-mycli-${NB_USER}.sh"
    cat > "${TMP_SCRIPT}" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
python -m pip install mycli || true
BASH
    chmod +x "${TMP_SCRIPT}"
    su - ${NB_USER:-jovyan} -s /bin/bash -c "${TMP_SCRIPT}" || true
    rm -f "${TMP_SCRIPT}"
else
    echo "⚠️  Python/pip not available. mycli requires Python."
    echo "Please install python-base feature first."
    exit 1
fi

# Create mycli configuration directory
NB_USER=${NB_USER:-jovyan}
HOME_DIR="/home/${NB_USER}"

mkdir -p "${HOME_DIR}/.myclirc"

cat > "${HOME_DIR}/.myclirc" << 'EOF'
[main]
# Multi-line mode allows breaking up the sql statements into multiple lines
multi_line = True

# Enables context-sensitive auto-completion
smart_completion = True

# Show/hide the informational toolbar
show_bottom_toolbar = True

# Syntax highlighting
syntax_style = default

# Number of lines to show in the suggestion menu
suggestion_width = 75

# Character used for the query history file
history_file = ~/.mycli-history

# log_file location
log_file = ~/.mycli.log

# Default log level
log_level = INFO

# Timing of sql statements
timing = True

# Table format (ascii, double, github, psql, etc.)
table_format = psql

# Syntax style
syntax_style = default

# Wider completion menus
wider_completion_menu = True

# Show/hide query execution time
timing = True

# Enable auto-refresh for auto-completion
auto_refresh_completions = True

# Key bindings (vi or emacs)
key_bindings = emacs
EOF

chown -R ${NB_UID:-1001}:${NB_GID:-1001} "${HOME_DIR}/.myclirc" 2>/dev/null || true

# Verify installation
echo ""
echo "✅ Verifying mycli installation..."
mycli --version

echo ""
echo "✅ mycli installed successfully!"
echo ""
echo "mycli features:"
echo "  - Smart autocomplete (context-aware)"
echo "  - Syntax highlighting"
echo "  - Multi-line queries"
echo "  - Query history"
echo "  - Vi/Emacs key bindings"
echo "  - Works with MySQL and MariaDB"
echo ""
echo "Example usage:"
echo "  mycli mysql://user:password@localhost:3306/database"
echo "  mycli -h localhost -u root -D mydb"
echo ""
echo "Useful mycli commands:"
echo "  \\dt              - List tables"
echo "  \\d table_name    - Describe table"
echo "  \\timing          - Toggle query timing"
echo "  \\e               - Edit query in editor"
echo "  \\q               - Quit"
echo "===================================================================="
