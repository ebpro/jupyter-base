# Database Features Summary

**Created**: 2025-12-18

## New Features

### 1. postgresql-client
**Location**: `.devcontainer/features/postgresql-client/`

**Purpose**: PostgreSQL client tools for database connectivity

**Components**:
- `psql` - Interactive PostgreSQL terminal
- `pg_dump` - Database backup utility
- `pg_restore` - Database restore utility
- `pg_isready` - Connection health check
- `pgcli` - Enhanced CLI with autocomplete (optional)
- `libpq-dev` - Development headers (optional)

**Options**:
- `version`: PostgreSQL version (14, 15, 16, 17, or 'latest')
- `installPgcli`: Install pgcli (default: true)
- `installLibpq`: Install libpq-dev headers (default: true)

**Dependencies**: base-apt

**Example Usage**:
```bash
psql -h localhost -U postgres -d mydb
pg_dump -h localhost -U postgres mydb > backup.sql
pgcli postgresql://user:password@localhost:5432/database
```

---

### 2. mysql-client
**Location**: `.devcontainer/features/mysql-client/`

**Purpose**: MySQL/MariaDB client tools for database connectivity

**Components**:
- `mysql` - Interactive MySQL terminal
- `mysqldump` - Database backup utility
- `mysqladmin` - Server administration
- `mysqlcheck` - Table checking and repair
- `mycli` - Enhanced CLI with autocomplete (optional)
- `libmysqlclient-dev` - Development headers (optional)

**Options**:
- `clientType`: "mysql" or "mariadb" (default: "mysql")
- `installMycli`: Install mycli (default: true)
- `installLibmysqlclient`: Install dev headers (default: true)

**Dependencies**: base-apt

**Example Usage**:
```bash
mysql -h localhost -u root -p mydb
mysqldump -h localhost -u root -p mydb > backup.sql
mycli mysql://user:password@localhost:3306/database
```

---

### 3. java-db
**Location**: `.devcontainer/features/java-db/`

**Purpose**: Meta-feature combining Java development with database clients

**Components** (via dependencies):
- Java JDK (via java-jdk)
- Maven + Gradle (via java-maven, java-gradle)
- PostgreSQL client (via postgresql-client)
- MySQL client (optional)

**Options**:
- `jdkVersion`: JDK version to use (default: "21")
- `includeMySQL`: Also install MySQL client (default: false)

**Dependencies**: java-jdk, java-maven, java-gradle, postgresql-client

**Use Cases**:
- Spring Boot applications with PostgreSQL
- JDBC development with multiple databases
- Microservices with database connectivity
- Database migration development (Flyway/Liquibase in Maven)

**Example Workflow**:
```xml
<!-- pom.xml -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-data-jpa</artifactId>
</dependency>
<dependency>
    <groupId>org.postgresql</groupId>
    <artifactId>postgresql</artifactId>
</dependency>
```

```bash
# Test database connectivity
psql -h localhost -U postgres -d myapp

# Run Spring Boot with PostgreSQL
mvn spring-boot:run
```

---

### 4. python-db
**Location**: `.devcontainer/features/python-db/`

**Purpose**: Python database libraries and tools for data science and development

**Components**:
- `psycopg2` / `psycopg2-binary` - PostgreSQL adapter
- `pymysql` - MySQL adapter (optional)
- `mysql-connector-python` - MySQL official connector (optional)
- `sqlalchemy` - ORM and database toolkit (optional)
- `alembic` - Database migrations (optional)
- `pandas` - DataFrame support for SQL queries (optional)
- `ipython-sql` / `jupysql` - Jupyter SQL magic (optional)
- `sqlparse` - SQL formatting

**Options**:
- `includeMySQL`: Install MySQL libraries (default: false)
- `installSQLAlchemy`: Install SQLAlchemy + Alembic (default: true)
- `installPandas`: Install pandas (default: true)
- `installNotebookExtensions`: Install Jupyter SQL magic (default: true)

**Dependencies**: python-base, postgresql-client

**Use Cases**:
- Data science notebooks with database queries
- ETL pipelines with SQLAlchemy
- Database-driven analytics
- SQL teaching and demonstrations

**Example Usage**:

Python Script:
```python
import psycopg2
conn = psycopg2.connect('dbname=mydb user=postgres')
cursor = conn.cursor()
cursor.execute('SELECT * FROM users')
```

SQLAlchemy:
```python
from sqlalchemy import create_engine
engine = create_engine('postgresql://user:pass@localhost/mydb')
```

Jupyter Notebook:
```python
%load_ext sql
%sql postgresql://user:pass@localhost/mydb
%%sql
SELECT * FROM users LIMIT 10;
```

pandas:
```python
import pandas as pd
df = pd.read_sql_query('SELECT * FROM users', conn)
```

---

## New Profiles

### 12-00-java-db
**Purpose**: Java database development (Spring Boot, JDBC, Hibernate)

**Inherits from**: 11-00-dev-java-sdk

**Features**:
- Java JDK 21
- Maven + Gradle
- PostgreSQL client

**Use Case**: Backend Java development with PostgreSQL

---

### 12-01-java-db-25
**Purpose**: Java database development with latest JDK

**Inherits from**: 12-00-java-db

**Features**: Same as 12-00 but with JDK 25

---

### 21-00-python-db
**Purpose**: Python data science with database connectivity

**Inherits from**: 20-00-data-science

**Features**:
- Python conda stack
- Jupyter notebooks
- PostgreSQL client
- Python database libraries (psycopg2, SQLAlchemy, pandas)
- Jupyter SQL magic extensions

**Use Case**: Data analysis notebooks querying databases

---

### 21-01-quarto-lecture-db
**Purpose**: Teaching notebooks with SQL demonstrations

**Inherits from**: 20-01-quarto-lecture

**Features**:
- Quarto publishing
- Jupyter notebooks
- PostgreSQL client
- Python database libraries
- SQL magic for live demos

**Use Case**: Database courses, SQL tutorials, data science teaching

---

## Design Philosophy

### No JDBC JARs / No Flyway Feature
As requested, JDBC drivers and Flyway are **NOT** included as features. Rationale:

1. **JDBC Drivers**: Should be build dependencies in Maven/Gradle
   ```xml
   <dependency>
       <groupId>org.postgresql</groupId>
       <artifactId>postgresql</artifactId>
       <version>42.7.1</version>
   </dependency>
   ```

2. **Flyway/Liquibase**: Should be Maven/Gradle plugins
   ```xml
   <plugin>
       <groupId>org.flywaydb</groupId>
       <artifactId>flyway-maven-plugin</artifactId>
       <version>10.4.1</version>
   </plugin>
   ```
   
   Run via Maven:
   ```bash
   mvn flyway:migrate
   mvn flyway:info
   ```

### Feature Granularity
- **Client Tools** (postgresql-client, mysql-client): Separate, reusable
- **Meta-Features** (java-db, python-db): Compose other features
- **No Duplication**: Each tool installed exactly once
- **Caching**: Separate layers for different concerns

### Integration Points

**Java Workflow**:
```
java-jdk → postgresql-client → JDBC (in pom.xml) → Spring Boot
```

**Python Workflow**:
```
python-base → postgresql-client → psycopg2 → SQLAlchemy → pandas
```

**Notebook Workflow**:
```
jupyter-kernels → python-db → %sql magic → SQL cells
```

---

## Validation

All features validated with production validator:
```bash
python3 scripts/validate-feature-deps.py --profile profiles/12-00-java-db
python3 scripts/validate-feature-deps.py --profile profiles/21-00-python-db
```

Expected results:
- ✓ No circular dependencies
- ✓ Valid topological sort
- ✓ All provides/dependsOn correct
- ⚠ Parent-provided dependencies (expected warnings)

---

## Next Steps

1. **Test Builds**: Build containers with new profiles
   ```bash
   ./build.sh 12-00-java-db
   ./build.sh 21-00-python-db
   ```

2. **Runtime Testing**: Verify database connectivity
   ```bash
   docker run -it IMAGE psql --version
   docker run -it IMAGE python3 -c "import psycopg2; print(psycopg2.__version__)"
   ```

3. **Integration Tests**: Test with actual databases
   - Docker Compose with PostgreSQL
   - Connect from container
   - Run queries

4. **Documentation**: Update README with database profiles

---

## Files Created

**Features** (8 files):
- `.devcontainer/features/postgresql-client/feature.json`
- `.devcontainer/features/postgresql-client/install.sh`
- `.devcontainer/features/mysql-client/feature.json`
- `.devcontainer/features/mysql-client/install.sh`
- `.devcontainer/features/java-db/feature.json`
- `.devcontainer/features/java-db/install.sh`
- `.devcontainer/features/python-db/feature.json`
- `.devcontainer/features/python-db/install.sh`

**Profiles** (4 files):
- `profiles/12-00-java-db`
- `profiles/12-01-java-db-25`
- `profiles/21-00-python-db`
- `profiles/21-01-quarto-lecture-db`

**Total**: 12 new files
