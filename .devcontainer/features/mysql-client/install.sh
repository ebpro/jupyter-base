#!/usr/bin/env bash
set -euo pipefail

# MySQL/MariaDB Client Tools Installation
# Installs mysql, mysqldump, and optionally mycli

CLIENT_TYPE="${CLIENTTYPE:-mysql}"
INSTALL_MYCLI="${INSTALLMYCLI:-true}"
INSTALL_LIBMYSQLCLIENT="${INSTALLLIBMYSQLCLIENT:-true}"

echo "===================================================================="
echo "Feature: MySQL/MariaDB Client Tools"
echo "===================================================================="
echo "Client Type: ${CLIENT_TYPE}"
echo "Install mycli: ${INSTALL_MYCLI}"
echo "Install libmysqlclient-dev: ${INSTALL_LIBMYSQLCLIENT}"
echo "===================================================================="

export DEBIAN_FRONTEND=noninteractive
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

# Install mycli if requested
if [ "${INSTALL_MYCLI}" = "true" ]; then
    echo "📦 Installing mycli (enhanced MySQL CLI)..."
    
    # Install via pip if Python is available, otherwise skip
    if command -v pip3 >/dev/null 2>&1; then
        pip3 install --no-cache-dir mycli
    else
        echo "⚠️  Python not available, skipping mycli installation"
        INSTALL_MYCLI="false"
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

# Verify installation
echo ""
echo "✅ Verifying MySQL client installation..."
mysql --version
mysqldump --version
mysqladmin --version

if [ "${INSTALL_MYCLI}" = "true" ]; then
    if command -v mycli >/dev/null 2>&1; then
        mycli --version
    fi
fi

echo ""
echo "✅ MySQL client tools installed successfully!"
echo ""
echo "Available commands:"
echo "  - mysql: Interactive MySQL terminal"
echo "  - mysqldump: Database backup utility"
echo "  - mysqladmin: MySQL server administration"
echo "  - mysqlcheck: Check and repair tables"
if [ "${INSTALL_MYCLI}" = "true" ]; then
    echo "  - mycli: Enhanced MySQL CLI with autocomplete"
fi
echo ""
echo "Example usage:"
echo "  mysql -h localhost -u root -p mydb"
echo "  mysqldump -h localhost -u root -p mydb > backup.sql"
if [ "${INSTALL_MYCLI}" = "true" ]; then
    echo "  mycli mysql://user:password@localhost:3306/database"
fi
echo "===================================================================="
