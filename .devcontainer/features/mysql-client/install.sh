#!/usr/bin/env bash
set -euo pipefail

# MySQL/MariaDB Client Tools Installation
# Installs mysql, mysqldump, and development libraries

CLIENT_TYPE="${CLIENTTYPE:-mysql}"
INSTALL_LIBMYSQLCLIENT="${INSTALLLIBMYSQLCLIENT:-true}"

echo "===================================================================="
echo "Feature: MySQL/MariaDB Client Tools"
echo "===================================================================="
echo "Client Type: ${CLIENT_TYPE}"
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
echo "  - mysqldump: Database backup utility"
echo "  - mysqladmin: MySQL server administration"
echo "  - mysqlcheck: Check and repair tables"
echo ""
echo "Example usage:"
echo "  mysql -h localhost -u root -p mydb"
echo "  mysqldump -h localhost -u root -p mydb > backup.sql"
echo ""
echo "For enhanced CLI with autocomplete, install mysql-client-cli feature"
