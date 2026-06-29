#!/usr/bin/env bash
set -euo pipefail

# PostgreSQL Client Tools Installation
# Installs psql, pg_dump, pg_restore, libpq libraries, and pgcli enhanced CLI

VERSION="${VERSION:-16}"
if command -v fh_resolve_version >/dev/null 2>&1; then
    # central versions.json uses key 'postgresql'
    RESOLVED=$(fh_resolve_version "postgresql" || true)
    if [ -n "${RESOLVED}" ]; then
        VERSION="${RESOLVED}"
    fi
    if command -v fh_write_history >/dev/null 2>&1; then
        fh_write_history "{\"feature\":\"postgresql-client\",\"resolved_version\":\"${VERSION}\"}"
    fi
fi
INSTALL_LIBPQ="${INSTALLLIBPQ:-true}"
INSTALL_PGCLI="${INSTALLPGCLI:-true}"

echo "===================================================================="
echo "Feature: PostgreSQL Client Tools"
echo "===================================================================="
echo "PostgreSQL Version: ${VERSION}"
echo "Install libpq-dev: ${INSTALL_LIBPQ}"
echo "Install pgcli: ${INSTALL_PGCLI}"
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

# Install pgcli if requested
if [ "${INSTALL_PGCLI}" = "true" ]; then
    echo ""
    echo "📦 Installing pgcli (enhanced PostgreSQL CLI)..."

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
        "${CONDA_DIR}/bin/pip" install pgcli || echo "⚠️  pgcli installation failed, continuing..."
    elif command -v pip3 >/dev/null 2>&1; then
        # Run as NB_USER to use user's pip cache
        TMP_SCRIPT="/tmp/install-pgcli-${NB_USER}.sh"
        cat > "${TMP_SCRIPT}" <<'EOFSCRIPT'
#!/usr/bin/env bash
set -euo pipefail
python3 -m pip install --break-system-packages pgcli || exit 0
EOFSCRIPT
        chmod +x "${TMP_SCRIPT}"
        su - ${NB_USER} -s /bin/bash -c "${TMP_SCRIPT}" || echo "⚠️  pgcli installation failed, continuing..."
        rm -f "${TMP_SCRIPT}"
    else
        echo "⚠️  pip not found, skipping pgcli installation"
    fi

    if command -v pgcli >/dev/null 2>&1; then
        echo "✅ pgcli installed successfully!"
        pgcli --version || true
    fi
fi

# Verify installation
echo ""
echo "✅ Verifying PostgreSQL client installation..."
psql --version
pg_dump --version
pg_isready --version

echo ""
echo "✅ PostgreSQL client tools installed successfully!"
echo ""
echo "Available commands:"
echo "  - psql: Interactive PostgreSQL terminal"
if [ "${INSTALL_PGCLI}" = "true" ] && command -v pgcli >/dev/null 2>&1; then
    echo "  - pgcli: Enhanced PostgreSQL CLI with autocomplete and syntax highlighting"
fi
echo "  - pg_dump: Database backup utility"
echo "  - pg_restore: Database restore utility"
echo "  - pg_isready: Check PostgreSQL server availability"
echo ""
echo "Example usage:"
echo "  psql -h localhost -U postgres -d mydb"
if [ "${INSTALL_PGCLI}" = "true" ] && command -v pgcli >/dev/null 2>&1; then
    echo "  pgcli -h localhost -U postgres -d mydb"
fi
echo "  pg_dump -h localhost -U postgres mydb > backup.sql"
echo ""
