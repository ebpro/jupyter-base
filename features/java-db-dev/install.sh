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

# Java Database Development Meta-Feature
# This is a meta-feature that combines Java development with database clients
# All actual installation is done by dependency features

JDK_VERSION="${JDKVERSION:-21}"
INCLUDE_MYSQL="${INCLUDEMYSQL:-false}"

echo "===================================================================="
echo "Feature: Java Database Development Stack"
echo "===================================================================="
echo "JDK Version: ${JDK_VERSION}"
echo "Include MySQL: ${INCLUDE_MYSQL}"
echo "===================================================================="

echo "ℹ️  This is a meta-feature. All components are installed via dependencies:"
echo ""
echo "Java Components (from dependencies):"
echo "  ✓ java-jdk: JDK ${JDK_VERSION}"
echo "  ✓ java-maven: Maven build tool"
echo "  ✓ java-gradle: Gradle build tool"
echo ""
echo "Database Clients (from dependencies):"
echo "  ✓ postgresql-client: PostgreSQL client tools (psql, pg_dump, pgcli)"
if [ "${INCLUDE_MYSQL}" = "true" ]; then
    echo "  ✓ mysql-client: MySQL client tools (mysql, mysqldump, mycli)"
fi
echo ""

# Verify all components are available
echo "✅ Verifying Java Database Development stack..."

# The JDK, Maven and Gradle are installed via SDKMAN (features java-sdkman,
# java-maven, java-gradle), whose bin dirs are only added to PATH by shell
# profiles. This verification can run in a non-login, non-interactive build
# shell where that PATH is not loaded, so source SDKMAN init once here to put
# every SDKMAN binary (java, mvn, gradle, ...) on the PATH before the checks
# below. If SDKMAN init is absent, the absolute-path fallback for `java`
# still applies.
for _home in "${HOME:-}" "$(getent passwd "${NB_USER:-jovyan}" 2>/dev/null | cut -d: -f6 || true)"; do
    [ -n "${_home}" ] || continue
    if [ -s "${_home}/.sdkman/bin/sdkman-init.sh" ]; then
        set +u
        # shellcheck source=/dev/null
        source "${_home}/.sdkman/bin/sdkman-init.sh" >/dev/null 2>&1 || true
        set -u
        break
    fi
done

# Check Java
# Resolve `java` explicitly before declaring it missing: a plain PATH lookup
# works once the SDKMAN PATH is sourced above, with an absolute-path fallback
# in case SDKMAN init was absent.
resolve_java_bin() {
    local candidate dir
    local build_user_home
    build_user_home="$(getent passwd "${NB_USER:-jovyan}" 2>/dev/null | cut -d: -f6 || true)"

    # 1. Plain PATH lookup (SDKMAN PATH already sourced above)
    candidate="$(command -v java || true)"
    if [ -n "${candidate}" ]; then
        printf '%s\n' "${candidate}"
        return 0
    fi

    # 2. Absolute SDKMAN candidate path (last resort, if sdkman-init.sh absent)
    for dir in "${SDKMAN_DIR:-${HOME:-}/.sdkman}" "${build_user_home:+${build_user_home}/.sdkman}"; do
        [ -n "${dir}" ] || continue
        if [ -x "${dir}/candidates/java/current/bin/java" ]; then
            printf '%s\n' "${dir}/candidates/java/current/bin/java"
            return 0
        fi
    done

    return 1
}

JAVA_BIN="$(resolve_java_bin || true)"
if [ -n "${JAVA_BIN}" ]; then
    echo "  ✓ Java: $("${JAVA_BIN}" -version 2>&1 | head -n 1)"
else
    echo "  ✗ Java not found"
    exit 1
fi

# Check Maven
if command -v mvn >/dev/null 2>&1; then
    echo "  ✓ Maven: $(mvn --version | head -n 1)"
else
    echo "  ✗ Maven not found"
    exit 1
fi

# Check Gradle
if command -v gradle >/dev/null 2>&1; then
    echo "  ✓ Gradle: $(gradle --version | grep "Gradle" | head -n 1)"
else
    echo "  ✗ Gradle not found"
    exit 1
fi

# Check PostgreSQL
if command -v psql >/dev/null 2>&1; then
    echo "  ✓ PostgreSQL: $(psql --version)"
else
    echo "  ✗ PostgreSQL client not found"
    exit 1
fi

# Check MySQL if requested
if [ "${INCLUDE_MYSQL}" = "true" ]; then
    if command -v mysql >/dev/null 2>&1; then
        echo "  ✓ MySQL: $(mysql --version)"
    else
        echo "  ⚠️  MySQL client not found (check dependencies)"
    fi
fi

echo ""
echo "✅ Java Database Development stack ready!"
echo ""
echo "Typical Java+DB development workflow:"
echo ""
echo "1. Spring Boot + PostgreSQL:"
echo "   - Add to pom.xml: spring-boot-starter-data-jpa, postgresql"
echo "   - Configure: spring.datasource.url=jdbc:postgresql://localhost:5432/mydb"
echo "   - Test connection: psql -h localhost -U postgres"
echo ""
echo "2. JDBC Development:"
echo "   - Add JDBC driver to Maven/Gradle dependencies"
echo "   - Use provided psql/mysql clients for DB inspection"
echo ""
echo "3. Database Migrations:"
echo "   - Flyway: Add to Maven/Gradle dependencies"
echo "   - Liquibase: Add to Maven/Gradle dependencies"
echo "   - Run migrations in Maven: mvn flyway:migrate"
echo ""
echo "===================================================================="
