# Docker Compose Files for Profiles

This directory contains devcontainer configurations for each profile, co-locating `devcontainer.json` and `docker-compose.yml` files for easy discovery and management.

## Layout

```
/devcontainer/
├── README.md                          # This file
├── GENERATION.md                      # Generation workflow docs
├── template/                           # Reusable templates for common services
│   ├── devcontainer.json
│   ├── docker-compose.dind.yml
│   ├── docker-compose.postgres.yml
│   └── docker-compose.mysql.yml
└── service-templates/                  # Service snippets for generation
    ├── dind.yml
    ├── postgres.yml
    └── ...

/generated/devcontainer/                # Auto-generated (gitignored)
└── <profile>/
    ├── devcontainer.json
    └── docker-compose.yml
```

## Naming Conventions

- **Canonical:** `docker-compose.yml` — full development environment for the profile.
- **Variants:** `docker-compose.<variant>.yml` — specific sidecar or service subset (e.g., `.dind.yml`, `.db.yml`, `.k3s.yml`).
- **Templates:** Use `template/` for reusable building blocks; copy and customize for each profile.

## Usage

### Starting a full environment

From the repository root:

```bash
# Start services in background
docker compose -f generated/devcontainer/<profile>/docker-compose.yml up -d

# Attach to the dev container
docker compose -f generated/devcontainer/<profile>/docker-compose.yml exec devcontainer /bin/zsh -l
```

### Stopping and cleanup

```bash
# Stop services
docker compose -f generated/devcontainer/<profile>/docker-compose.yml down

# Stop and remove volumes (careful: deletes data)
docker compose -f generated/devcontainer/<profile>/docker-compose.yml down --volumes
```

### Using with VS Code

VS Code auto-discovers devcontainer configurations. The generated configs reference compose files with relative paths.

1. Generate the profile:
   ```bash
   python3 scripts/generate-devcontainer-json.py <profile>
   ```
2. Open Command Palette (Cmd/Ctrl+Shift+P)
3. Run "Dev Containers: Open Folder in Container..."
4. Select the generated profile from `generated/devcontainer/<profile>/`

## Best Practices

### Sidecar vs in-container services

- **Sidecar pattern (recommended):** Run privileged services (dind, databases) in separate containers. The dev container runs as non-root user (`jovyan`) and connects to sidecars over the network.
- **In-container daemons:** Avoid running `dockerd` or databases inside the dev container — it complicates permissions, requires root startup, and limits flexibility.

### Permissions & user

- Dev container should start as `jovyan` (non-root) when services run in sidecars.
- Sidecars (dind, postgres) run as root or their default user.
- Cert/socket ownership: dind generates TLS certs owned by root; the dev container mounts them read-only (`/certs/client:ro`) and uses `DOCKER_CERT_PATH` + `DOCKER_TLS_VERIFY`.

### macOS caveats

- **dind:** Docker-in-Docker with `--privileged` may be unreliable on macOS Docker Desktop due to VM limitations. For macOS:
  - Prefer mounting host socket: `-v /var/run/docker.sock:/var/run/docker.sock`.
  - Or use dind on a Linux VM/remote host for full functionality.
- **Volumes:** Named volumes are recommended over bind mounts for dind `/var/lib/docker` on macOS.

### Security

- **TLS for Docker:** Use `DOCKER_TLS_CERTDIR=/certs` (default in `docker:XX-dind`) for secure TCP connections. Avoid plain TCP (port 2375) in production.
- **Host socket:** Mounting `/var/run/docker.sock` grants full control over the host Docker daemon — use only on trusted dev machines.
- **Credentials:** Use `.env` files (not committed) for secrets (`GITHUB_PAT`, `DOCKERHUB_TOKEN`, `DB_PASSWORD`). Reference them with `${VAR:-default}` in compose.

### Networking

- All services in a profile should share a network (e.g., `notebooknet` or `devnet`) so they can resolve by service name (`docker`, `postgres`, `mysql`).
- Use `depends_on` with `condition: service_healthy` to ensure sidecars are ready before starting the dev container.

### Healthchecks

- Always add healthchecks to sidecar services so `depends_on` can wait for readiness:
  - dind: `docker info`
  - postgres: `pg_isready -U <user>`
  - mysql: `mysqladmin ping`

## Templates

### Available Service Templates

The following service templates are available in `devcontainer/service-templates/`:

- **dind.yml** - Docker-in-Docker (docker:27-dind) with TLS certificates
- **postgres.yml** - PostgreSQL with Alpine (configurable version)
- **mysql.yml** - MySQL 8.0 with persistent data
- **mongo.yml** - MongoDB 8.0 with persistent data
- **redis.yml** - Redis 7 with persistent data
- **registry.yml** - Container registry (registry:2)
- **k3s.yml** - Lightweight Kubernetes (k3s) cluster
- **buildkit.yml** - BuildKit daemon for advanced container builds

Each template defines environment variables with sensible defaults (e.g., `${POSTGRES_VERSION:-16}`).

### Docker-in-Docker (dind)

- File: `template/docker-compose.dind.yml`
- Provides: Isolated Docker daemon with TLS cert volumes.
- Use case: Container build/run demos, CI/CD teaching, Docker-in-Docker workflows.

### PostgreSQL

- File: `template/docker-compose.postgres.yml`
- Provides: PostgreSQL 16 with init scripts support.
- Use case: Database teaching, SQL queries, JDBC examples.

### MySQL

- File: `template/docker-compose.mysql.yml`
- Provides: MySQL 8.0 with init scripts support.
- Use case: Database teaching, SQL queries, JDBC examples.

## Environment Variables

Compose files use environment variables with defaults:

- `IMAGE_REPO` — Docker registry (default: `ghcr.io/ebpro`)
- `IMAGE_NAME` — Image name (default: `solen`)
- `IMAGE_TAG` — Image tag (default: `<profile>-develop`)
- `DB_USERNAME`, `DB_PASSWORD`, `DB_NAME` — Database credentials
- `GITHUB_PAT`, `DOCKERHUB_TOKEN` — CI tokens (optional, for publishing)

Create a `.env` file in the repository root or pass via shell:

```bash
IMAGE_TAG=quarto-lecture-containers-latest docker compose -f compose/quarto-lecture-containers/docker-compose.dind.yml up -d
```

## Integration with Features

Features that install daemons (e.g., `docker-dind`, `postgresql-client`) should:

- Provide usage instructions for compose sidecars (not in-container daemon start).
- Document required environment variables and volume mounts.
- Optionally provide a sample start script (`/usr/local/bin/start-<service>`) for advanced in-container use (not recommended for dind).

## Creating a New Profile Compose

1. Copy a template from `template/`:
   ```bash
   mkdir -p devcontainer/service-templates/<new-service>
   cp devcontainer/template/docker-compose.dind.yml devcontainer/service-templates/
   ```
2. Add `@services:<service>` to the profile.
3. Generate:
   ```bash
   python3 scripts/generate-devcontainer-json.py <profile>
   ```
4. Test startup:
   ```bash
   docker compose -f generated/devcontainer/<profile>/docker-compose.yml up -d
   docker compose -f generated/devcontainer/<profile>/docker-compose.yml exec devcontainer /bin/zsh -l
   ```

## Questions & Support

- See `/profiles/README.md` for profile descriptor conventions.
- For macOS issues, prefer host socket or run on Linux VM.
