#!/usr/bin/env bash
set -euo pipefail

# PostgreSQL Client Tools Installation
# Installs psql, pg_dump, pg_restore, and optionally pgcli

VERSION="${VERSION:-16}"
INSTALL_PGCLI="${INSTALLPGCLI:-true}"
INSTALL_LIBPQ="${INSTALLLIBPQ:-true}"

echo "===================================================================="
echo "Feature: PostgreSQL Client Tools"
echo "===================================================================="
echo "PostgreSQL Version: ${VERSION}"
echo "Install pgcli: ${INSTALL_PGCLI}"
echo "Install libpq-dev: ${INSTALL_LIBPQ}"
echo "===================================================================="

# Determine actual PostgreSQL version
if [ "${VERSION}" = "latest" ]; then
    PG_VERSION="17"
else
    PG_VERSION="${VERSION}"
fi

echo "📦 Adding PostgreSQL APT repository..."

# Install prerequisites
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

# Add PostgreSQL repository
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" | \
    tee /etc/apt/sources.list.d/pgdg.list > /dev/null

apt-get update -qq

echo "📦 Installing PostgreSQL ${PG_VERSION} client tools..."

# Install PostgreSQL client
apt-get install -y --no-install-recommends \
    "postgresql-client-${PG_VERSION}"

# Install development libraries if requested
if [ "${INSTALL_LIBPQ}" = "true" ]; then
    echo "📦 Installing libpq-dev..."
    apt-get install -y --no-install-recommends \
        libpq-dev
fi

# Install pgcli if requested
if [ "${INSTALL_PGCLI}" = "true" ]; then
    echo "📦 Installing pgcli (enhanced PostgreSQL CLI)..."
    
    # Install via pip if Python is available, otherwise via apt
    if command -v pip3 >/dev/null 2>&1; then
        pip3 install --no-cache-dir pgcli
    else
        apt-get install -y --no-install-recommends pgcli
    fi
fi

# Create PostgreSQL client configuration directory
mkdir -p /etc/postgresql-common
cat > /etc/postgresql-common/psqlrc << 'EOF'
-- PostgreSQL client configuration
\set QUIET 1
\timing on
\x auto
\set VERBOSITY verbose
\set HISTFILE ~/.psql_history- :DBNAME
\set HISTCONTROL ignoredups
\set COMP_KEYWORD_CASE upper
\pset null '¤'
\pset linestyle unicode
\pset border 2
\unset QUIET
EOF

# Verify installation
echo ""
echo "✅ Verifying PostgreSQL client installation..."
psql --version
pg_dump --version
pg_isready --version

if [ "${INSTALL_PGCLI}" = "true" ]; then
    if command -v pgcli >/dev/null 2>&1; then
        pgcli --version
    fi
fi

echo ""
echo "✅ PostgreSQL client tools installed successfully!"
echo ""
echo "Available commands:"
echo "  - psql: Interactive PostgreSQL terminal"
echo "  - pg_dump: Database backup utility"
echo "  - pg_restore: Database restore utility"
echo "  - pg_isready: Check PostgreSQL server availability"
if [ "${INSTALL_PGCLI}" = "true" ]; then
    echo "  - pgcli: Enhanced PostgreSQL CLI with autocomplete"
fi
echo ""
echo "Example usage:"
echo "  psql -h localhost -U postgres -d mydb"
echo "  pg_dump -h localhost -U postgres mydb > backup.sql"
if [ "${INSTALL_PGCLI}" = "true" ]; then
    echo "  pgcli postgresql://user:password@localhost:5432/database"
fi
echo "===================================================================="
