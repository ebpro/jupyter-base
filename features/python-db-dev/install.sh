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

# Python Database Development Installation
# Installs Python database libraries and tools

INCLUDE_MYSQL="${INCLUDEMYSQL:-false}"
INSTALL_SQLALCHEMY="${INSTALLSQLALCHEMY:-true}"
INSTALL_PANDAS="${INSTALLPANDAS:-true}"
INSTALL_NOTEBOOK_EXTENSIONS="${INSTALLNOTEBOOKEXTENSIONS:-true}"

echo "===================================================================="
echo "Feature: Python Database Development"
echo "===================================================================="
echo "Include MySQL: ${INCLUDE_MYSQL}"
echo "Install SQLAlchemy: ${INSTALL_SQLALCHEMY}"
echo "Install pandas: ${INSTALL_PANDAS}"
echo "Install Notebook Extensions: ${INSTALL_NOTEBOOK_EXTENSIONS}"
echo "===================================================================="

# Determine Python executable (prefer conda if available)
if command -v conda >/dev/null 2>&1; then
    PYTHON_CMD="conda"
    INSTALL_METHOD="conda"
    echo "📦 Using conda for Python package installation"
elif command -v pip3 >/dev/null 2>&1; then
    PYTHON_CMD="pip3"
    INSTALL_METHOD="pip"
    echo "📦 Using pip for Python package installation"
else
    echo "❌ Error: Neither conda nor pip3 found"
    exit 1
fi

# Array to hold packages to install
PACKAGES=()

# PostgreSQL libraries (always installed)
echo ""
echo "📦 Adding PostgreSQL Python libraries..."
if [ "${INSTALL_METHOD}" = "conda" ]; then
    PACKAGES+=("psycopg2")
else
    PACKAGES+=("psycopg2-binary")
fi

# MySQL libraries (optional)
if [ "${INCLUDE_MYSQL}" = "true" ]; then
    echo "📦 Adding MySQL Python libraries..."
    PACKAGES+=("pymysql")
    PACKAGES+=("mysql-connector-python")
fi

# SQLAlchemy (optional but recommended)
if [ "${INSTALL_SQLALCHEMY}" = "true" ]; then
    echo "📦 Adding SQLAlchemy and related tools..."
    PACKAGES+=("sqlalchemy")
    PACKAGES+=("alembic")  # Database migrations
fi

# pandas (optional but common for data science)
if [ "${INSTALL_PANDAS}" = "true" ]; then
    echo "📦 Adding pandas for database results..."
    if [ "${INSTALL_METHOD}" = "pip" ]; then
        # Only add if not already installed (likely from python-conda)
        if ! python3 -c "import pandas" 2>/dev/null; then
            PACKAGES+=("pandas")
        fi
    fi
fi

# Jupyter SQL extensions (optional)
if [ "${INSTALL_NOTEBOOK_EXTENSIONS}" = "true" ]; then
    echo "📦 Adding Jupyter SQL magic extensions..."
    PACKAGES+=("ipython-sql")
    PACKAGES+=("jupysql")
    PACKAGES+=("sqlparse")  # SQL formatting
fi

# Install packages
if [ ${#PACKAGES[@]} -gt 0 ]; then
    echo ""
    echo "📦 Installing Python database packages..."

    if [ "${INSTALL_METHOD}" = "conda" ]; then
        conda install -y -n base "${PACKAGES[@]}" || {
            echo "⚠️  Some packages failed via conda, trying pip fallback..."
            # Run pip fallback as NB_USER so user's cache is used
            NB_USER=${NB_USER:-jovyan}
            TMP_SCRIPT="/tmp/pip-fallback-${NB_USER}.sh"
            cat > "${TMP_SCRIPT}" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
python3 -m pip install "${PACKAGES[@]}" || true
BASH
            chmod +x "${TMP_SCRIPT}"
            su - ${NB_USER} -s /bin/bash -c "${TMP_SCRIPT}" || true
            rm -f "${TMP_SCRIPT}"
        }
    else
        # Ensure notebook user pip cache exists and is owned to avoid warnings
        NB_USER=${NB_USER:-jovyan}
        NB_UID=${NB_UID:-1001}
        NB_GID=${NB_GID:-1001}
        HOME_DIR="/home/${NB_USER}"
        mkdir -p "${HOME_DIR}/.cache/pip" 2>/dev/null || true
        chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/.cache" 2>/dev/null || true
        TMP_SCRIPT="/tmp/pip-install-${NB_USER}.sh"
        cat > "${TMP_SCRIPT}" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
python3 -m pip install "${PACKAGES[@]}" || true
BASH
        chmod +x "${TMP_SCRIPT}"
        su - ${NB_USER} -s /bin/bash -c "${TMP_SCRIPT}" || true
        rm -f "${TMP_SCRIPT}"
    fi
fi

# Create example notebook configuration for SQL magic
if [ "${INSTALL_NOTEBOOK_EXTENSIONS}" = "true" ]; then
    echo ""
    echo "📝 Creating Jupyter SQL magic configuration..."

    mkdir -p /tmp/jupyter-sql-examples
    cat > /tmp/jupyter-sql-examples/sql-magic-example.md << 'EOF'
# Jupyter SQL Magic Examples

## Load SQL Magic Extension

```python
%load_ext sql
```

## Connect to PostgreSQL

```python
%sql postgresql://user:password@localhost:5432/database
```

## Run SQL Query

```sql
%%sql
SELECT * FROM users LIMIT 10;
```

## Query to DataFrame

```python
result = %sql SELECT * FROM users LIMIT 10
df = result.DataFrame()
```

## Using SQLAlchemy Connection

```python
from sqlalchemy import create_engine
engine = create_engine('postgresql://user:password@localhost:5432/database')

%sql engine
```

## Parameterized Queries

```python
user_id = 123
result = %sql SELECT * FROM users WHERE id = :user_id
```

## Connection String Examples

### PostgreSQL
- `postgresql://user:password@localhost:5432/database`
- `postgresql+psycopg2://user:password@localhost/database`

### MySQL
- `mysql+pymysql://user:password@localhost:3306/database`
- `mysql+mysqlconnector://user:password@localhost/database`

### SQLite
- `sqlite:///path/to/database.db`
EOF

    echo "   Example configuration created in /tmp/jupyter-sql-examples/"
fi

# Verify installation
echo ""
echo "✅ Verifying Python database packages..."

python3 << 'PYEOF'
import sys

packages = {
    "psycopg2": "PostgreSQL adapter",
    "sqlalchemy": "SQLAlchemy ORM",
    "alembic": "Database migrations",
    "pandas": "Data analysis",
    "sql": "Jupyter SQL magic"
}

print("\nInstalled packages:")
for package, description in packages.items():
    try:
        if package == "sql":
            __import__("sql.magic")
        else:
            __import__(package)
        version = ""
        try:
            mod = __import__(package)
            if hasattr(mod, "__version__"):
                version = f" v{mod.__version__}"
        except:
            pass
        print(f"  ✓ {package}{version} - {description}")
    except ImportError:
        print(f"  ⚠ {package} - {description} (not installed)")
PYEOF

echo ""
echo "✅ Python database development stack installed!"
echo ""
echo "Quick Start Examples:"
echo ""
echo "1. PostgreSQL with psycopg2:"
echo "   import psycopg2"
echo "   conn = psycopg2.connect('dbname=mydb user=postgres')"
echo ""
echo "2. SQLAlchemy ORM:"
echo "   from sqlalchemy import create_engine"
echo "   engine = create_engine('postgresql://user:pass@localhost/mydb')"
echo ""
echo "3. pandas SQL queries:"
echo "   import pandas as pd"
echo "   df = pd.read_sql_query('SELECT * FROM users', conn)"
echo ""
echo "4. Jupyter SQL magic:"
echo "   %load_ext sql"
echo "   %sql postgresql://user:pass@localhost/mydb"
echo "   %%sql SELECT * FROM users LIMIT 10"
echo ""
echo "Configuration examples: /tmp/jupyter-sql-examples/"
echo "===================================================================="
