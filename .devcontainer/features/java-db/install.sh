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

# Check Java
if command -v java >/dev/null 2>&1; then
    echo "  ✓ Java: $(java -version 2>&1 | head -n 1)"
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
