# Docker-in-Docker Setup for Quarto Lecture Profile

## Quick Start

Build and run the new profile:

```bash
# Build the image
./build.sh quarto-lecture-containers

# Run with Docker-in-Docker
docker run --rm -it \
  --privileged \
  -v "$PWD:/workspace" \
  -v docker-data:/var/lib/docker \
  -p 8888:8888 \
  solen:quarto-lecture-containers

# Inside container, Docker starts automatically
docker ps
docker run hello-world
```

> **Naming (UNVERIFIED):** `build.sh` takes the profile **positionally** (see `AGENTS.md`), not via a `--profile` flag. The generated profile/devcontainer label is **`quarto-containers`** (present in `generated/profiles/` and `generated/devcontainer/`), while **`quarto-lecture-containers`** is the name of the source matrix file (`profiles/matrix/quarto-lecture.yaml`) and the `devcontainer/quarto-lecture-containers/` template folder. Confirm which identifier `build.sh` expects before running.

## What Was Created

### 1. New Profile: `quarto-lecture-containers`
Source matrix: [profiles/matrix/quarto-lecture.yaml](profiles/matrix/quarto-lecture.yaml) (profiles are matrix-only; this generates the `quarto-containers` label)

Combines:
- ✅ Quarto with TeX (PDF output)
- ✅ Java 25 + build tools
- ✅ Jupyter notebooks
- ✅ PostgreSQL client + Python DB tools
- ✅ **Docker-in-Docker** (isolated, version-pinned)

### 2. Enhanced `docker-dind` Feature
> **[UNVERIFIED]** `.devcontainer/features/docker-dind/install.sh` is not in the current tree (no root `.devcontainer/`, no `features/docker-dind`). Docker-in-Docker is wired today via `@services:dind` in [profiles/matrix/quarto-lecture.yaml](profiles/matrix/quarto-lecture.yaml) (see `generated/profiles/quarto-containers`); the historical `install.sh` path could not be located.

New capabilities:
- ✅ Version pinning from `versions/versions.yaml` (SoT) (Docker 27.5.1, Compose 2.39.3)
- ✅ Auto-start via `/etc/startup.d/10-dockerd.sh`
- ✅ Health check: `docker-health` command
- ✅ BuildKit enabled by default

### 3. Improved `startup` Feature
> **[UNVERIFIED]** `.devcontainer/features/startup/install.sh` is not in the current tree (no `features/startup`). The `/etc/startup.d` auto-start mechanism could not be located; the closest existing feature is `features/container-init/` (not confirmed to provide it).

Now:
- ✅ Creates `/etc/startup.d` directory
- ✅ Runs all `.sh` scripts in startup.d on container start
- ✅ Auto-generated if not present in repo

### 4. DevContainer Template
[generated/devcontainer/quarto-containers/devcontainer.json](generated/devcontainer/quarto-containers/devcontainer.json) — untracked build output; regenerate with `.venv/bin/solen generate profiles --matrix profiles/matrix --out generated/profiles --chain` before use

VS Code devcontainer configuration with:
- Privileged mode for DinD
- Persistent Docker volume
- Docker extension pre-installed
- Auto-start via `postStartCommand`

## Usage Patterns

### Manual Daemon Control

```bash
# Start daemon manually
start-dockerd &

# Check health
docker-health

# View logs
tail -f /var/log/dockerd.log
```

### Teaching Examples

```bash
# Demo 1: Run a container
docker run -d --name demo nginx:alpine
docker ps
docker logs demo
docker stop demo

# Demo 2: Build an image
cat > Dockerfile <<EOF
FROM alpine:latest
RUN apk add --no-cache curl
CMD ["curl", "--version"]
EOF
docker build -t demo-image .
docker run demo-image

# Demo 3: Docker Compose
cat > docker-compose.yml <<EOF
services:
  web:
    image: nginx:alpine
    ports:
      - "8080:80"
EOF
docker-compose up -d
```

## Security Considerations

### Option 1: Privileged Mode (Current)
- ✅ Simple setup
- ✅ Full Docker functionality
- ⚠️ Container has elevated privileges

### Option 2: Sysbox Runtime (Production)
```bash
# On host: install Sysbox
curl -fsSL https://github.com/nestybox/sysbox/releases/download/v0.6.4/sysbox-ce_0.6.4-0.linux_amd64.deb \
  -o sysbox.deb
sudo apt install ./sysbox.deb

# Run container with Sysbox
docker run --runtime=sysbox-runc \
  -v "$PWD:/workspace" \
  solen:quarto-lecture-containers
```

### Option 3: Podman (Alternative)
Use the existing `bundle-container-runtimes` profile for rootless containers without privileges.

## Version Management

Pinned versions in [versions/versions.yaml](versions/versions.yaml) (SoT; synced to the root `versions.json` via `solen versions sync`):
- `docker-ce: 27.5.1`
- `docker-compose: 2.39.3`

Update versions there to pin across all builds.

## Troubleshooting

### Daemon won't start
```bash
# Check logs
cat /var/log/dockerd.log

# Manual start with debug
dockerd --debug
```

### Permission denied
```bash
# Ensure user in docker group
id jovyan | grep docker

# Re-add if needed
sudo usermod -aG docker jovyan
```

### Storage driver issues
Change in profile options:
```
@options:STORAGEDRIVER=vfs
```

## Next Steps

1. Build the profile: `./build.sh quarto-lecture-containers`
2. Test Docker inside: `docker run --privileged ... solen:quarto-lecture-containers`
3. For VS Code: copy devcontainer.json to `.devcontainer/` folder
4. For production: consider Sysbox runtime for security
