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

# MySQL/MariaDB Client Tools Installation
# Installs mysql, mysqldump, development libraries, and mycli enhanced CLI

CLIENT_TYPE="${CLIENTTYPE:-mysql}"
INSTALL_LIBMYSQLCLIENT="${INSTALLLIBMYSQLCLIENT:-true}"
INSTALL_MYCLI="${INSTALLMYCLI:-true}"

echo "===================================================================="
echo "Feature: MySQL/MariaDB Client Tools"
echo "===================================================================="
echo "Client Type: ${CLIENT_TYPE}"
echo "Install mycli: ${INSTALL_MYCLI}"
apt-get update -qq

if [ "${CLIENT_TYPE}" = "mariadb" ]; then
    echo "📦 Installing MariaDB client tools..."
    apt-get install -y --no-install-recommends \
        mariadb-client

    if [ "${INSTALL_LIBMYSQLCLIENT}" = "true" ]; then
        apt-get install -y --no-install-recommends \
            libmariadb-dev
    fi
else
    echo "📦 Installing MySQL client tools..."
    apt-get install -y --no-install-recommends \
        mysql-client

    if [ "${INSTALL_LIBMYSQLCLIENT}" = "true" ]; then
        apt-get install -y --no-install-recommends \
            libmysqlclient-dev
    fi
fi

# Create MySQL client configuration
mkdir -p ~/.mysql
cat > ~/.my.cnf << 'EOF'
[client]
# MySQL client configuration
auto-rehash
show-warnings
prompt="\u@\h [\d]> "

[mysql]
# Enable pager for large result sets
# pager=less -S
EOF

# Install mycli if requested
if [ "${INSTALL_MYCLI}" = "true" ]; then
    echo ""
    echo "📦 Installing mycli (enhanced MySQL/MariaDB CLI)..."

    # Ensure notebook user variables
    NB_USER=${NB_USER:-jovyan}
    NB_UID=${NB_UID:-1001}
    NB_GID=${NB_GID:-1001}
    HOME_DIR="/home/${NB_USER}"

    # Ensure pip cache owned by notebook user
    mkdir -p "${HOME_DIR}/.cache/pip" 2>/dev/null || true
    chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/.cache" 2>/dev/null || true

    # Prefer conda pip when available
    if [ -n "${CONDA_DIR:-}" ] && [ -f "${CONDA_DIR}/bin/pip" ]; then
        "${CONDA_DIR}/bin/pip" install mycli || echo "⚠️  mycli installation failed, continuing..."
    elif command -v pip3 >/dev/null 2>&1; then
        # Run as NB_USER to use user's pip cache
        TMP_SCRIPT="/tmp/install-mycli-${NB_USER}.sh"
        cat > "${TMP_SCRIPT}" <<'EOFSCRIPT'
#!/usr/bin/env bash
set -euo pipefail
python3 -m pip install mycli || exit 0
EOFSCRIPT
        chmod +x "${TMP_SCRIPT}"
        su - ${NB_USER} -s /bin/bash -c "${TMP_SCRIPT}" || echo "⚠️  mycli installation failed, continuing..."
        rm -f "${TMP_SCRIPT}"
    else
        echo "⚠️  pip not found, skipping mycli installation"
    fi

    if command -v mycli >/dev/null 2>&1; then
        echo "✅ mycli installed successfully!"
        mycli --version || true
    fi
fi

# Verify installation
echo ""
echo "✅ Verifying MySQL client installation..."
mysql --version
mysqldump --version
mysqladmin --version

echo ""
echo "✅ MySQL client tools installed successfully!"
echo ""
echo "Available commands:"
echo "  - mysql: Interactive MySQL terminal"
if [ "${INSTALL_MYCLI}" = "true" ] && command -v mycli >/dev/null 2>&1; then
    echo "  - mycli: Enhanced MySQL CLI with autocomplete and syntax highlighting"
fi
echo "  - mysqldump: Database backup utility"
echo "  - mysqladmin: MySQL server administration"
echo "  - mysqlcheck: Check and repair tables"
echo ""
echo "Example usage:"
echo "  mysql -h localhost -u root -p mydb"
if [ "${INSTALL_MYCLI}" = "true" ] && command -v mycli >/dev/null 2>&1; then
    echo "  mycli -h localhost -u root -p mydb"
fi
echo "  mysqldump -h localhost -u root -p mydb > backup.sql"
echo ""
echo "Tip: set INSTALL_MYCLI=true to install mycli (autocomplete CLI)"
