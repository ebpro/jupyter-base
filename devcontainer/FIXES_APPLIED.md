# DevContainer Configuration Updates - Best Practices Applied

## Summary

All devcontainer templates and service configurations have been updated to incorporate the best practices and fixes discovered during the quarto-lecture-containers sample development.

## Key Changes

### 1. Docker-in-Docker (dind) - Non-TLS Mode ✅

**Problem:** TLS certificate mode caused permission issues, complex volume mounting, and unreliable behavior on macOS.

**Solution:** Use non-TLS mode for development environments:
- Set `DOCKER_TLS_CERTDIR: ""` (empty string)
- Use port `2375` instead of `2376`
- Set `DOCKER_HOST=tcp://docker:2375` (no cert path needed)
- Remove certificate volume mounts

**Files Updated:**
- `devcontainer/template/docker-compose.dind.yml`
- `devcontainer/template/docker-compose.dind-postgres.yml` (new)
- `devcontainer/service-templates/dind.yml`
- `devcontainer/quarto-lecture-containers/docker-compose.dind.yml`

### 2. Improved Healthchecks ⏱️

**Problem:** Slow healthcheck intervals (30s) caused sluggish startup times.

**Solution:** Faster, more responsive healthchecks:
- dind: interval 5s, timeout 3s, retries 10, start_period 10s
- postgres/mysql/mongo/redis: interval 10s, timeout 5s, retries 5

**Rationale:** dind can respond quickly to `docker info`, so 5s is fine. Databases need slightly more time, so 10s is appropriate.

### 3. Service Dependencies with Healthchecks 🔗

**Best Practice:** Always use `condition: service_healthy` in `depends_on`:

```yaml
depends_on:
  docker:
    condition: service_healthy
  postgres:
    condition: service_healthy
```

This ensures services are fully ready before dependent containers start.

### 4. Restart Policies 🔄

**Added:** `restart: unless-stopped` to all sidecar services:
- Ensures services restart after system reboot or Docker restart
- Stops cleanly when explicitly stopped by user
- Applied to: dind, postgres, mysql, mongo, redis

### 5. Security - No External Port Exposure 🔒

**Removed:** Port mappings from service templates:
- Services communicate over internal Docker network
- No need to expose ports externally unless explicitly needed
- Prevents accidental exposure of database services

**Exception:** Port forwarding can be added in devcontainer.json if needed for external access.

### 6. Volume Mount Optimizations 💾

**Added:** `:cached` consistency mode for bind mounts on macOS:
```yaml
volumes:
  - ${PWD}:/home/jovyan/work/local:cached
```

**Benefits:** Improved I/O performance on macOS Docker Desktop/Colima.

### 7. Working Directory ���

**Added:** Explicit `working_dir` to devcontainer services:
```yaml
working_dir: /home/jovyan/work/local
```

Ensures commands run in the correct directory when the container starts.

### 8. Network Configuration 🌐

**Added:** Explicit network driver:
```yaml
networks:
  devnet:
    driver: bridge
```

Makes network configuration explicit and consistent.

### 9. Shell Environment Setup 🐚

**Updated:** `postCreateCommand` in devcontainer.json to configure DOCKER_HOST:
```json
"postCreateCommand": "echo 'unset DOCKER_HOST' >> ~/.zshrc && echo 'export DOCKER_HOST=tcp://docker:2375' >> ~/.zshrc && echo '✅ Dev container ready!'"
```

Ensures DOCKER_HOST is set in all shell sessions.

### 10. DevContainer JSON Fix 🔧

**Critical:** Never have both "image" and "dockerComposeFile" properties:
```json
{
  "dockerComposeFile": "docker-compose.yml",
  "service": "devcontainer",
  // ❌ DON'T add "image" property here
}
```

**Issue:** VS Code ignores compose file when both are present, creating a separate container.

## New Templates Created

### docker-compose.dind-postgres.yml

Complete template combining Docker-in-Docker and PostgreSQL services - the most common teaching environment setup:

- Main devcontainer service
- PostgreSQL 16 Alpine
- Docker 27-dind (non-TLS)
- All services on shared network
- Proper healthcheck dependencies
- Ready to use for container and database teaching

## Files Updated

### Templates
- ✅ `devcontainer/template/devcontainer.json`
- ✅ `devcontainer/template/docker-compose.dind.yml`
- ✅ `devcontainer/template/docker-compose.postgres.yml`
- ✅ `devcontainer/template/docker-compose.mysql.yml`
- ✅ `devcontainer/template/docker-compose.dind-postgres.yml` (new)

### Service Templates
- ✅ `devcontainer/service-templates/dind.yml`
- ✅ `devcontainer/service-templates/postgres.yml`
- ✅ `devcontainer/service-templates/mysql.yml`
- ✅ `devcontainer/service-templates/mongo.yml`
- ✅ `devcontainer/service-templates/redis.yml`

### Profile-Specific
- ✅ `devcontainer/quarto-lecture-containers/docker-compose.dind.yml`

### Documentation
- ✅ `devcontainer/README.md` - Added "Key Lessons Learned" section with DOs and DON'Ts

## Testing

All changes are based on proven working configuration from:
- `samples/quarto-lecture-containers/.devcontainer/`

Verified working with:
- ✅ VS Code Dev Containers extension
- ✅ Colima on macOS (Apple Silicon and Intel)
- ✅ Docker Desktop on macOS
- ✅ Linux Docker native

## Benefits

1. **Simpler:** No TLS certificate management complexity
2. **Faster:** Improved healthcheck intervals for quicker startup
3. **Reliable:** Non-TLS mode eliminates permission and mounting issues
4. **Secure:** No external port exposure by default
5. **Consistent:** All templates follow same patterns
6. **Documented:** Clear DOs and DON'Ts in README

## Migration Guide

If you have existing devcontainer configurations using the old templates:

1. **Update dind service:**
   - Change `DOCKER_TLS_CERTDIR: /certs` to `DOCKER_TLS_CERTDIR: ""`
   - Change `DOCKER_HOST=tcp://docker:2376` to `DOCKER_HOST=tcp://docker:2375`
   - Remove certificate volume mounts (`certs-ca`, `certs-client`)

2. **Update healthchecks:**
   - dind: interval 5s, retries 10, start_period 10s
   - databases: interval 10s, retries 5

3. **Add restart policies:**
   - Add `restart: unless-stopped` to all services

4. **Remove port mappings:**
   - Remove external port exposure unless specifically needed

5. **Update devcontainer.json:**
   - Remove "image" property if "dockerComposeFile" is present
   - Update postCreateCommand to set DOCKER_HOST

## Next Steps

- [ ] Test templates with other profiles (minimal, python-db, etc.)
- [ ] Create additional combined templates as needed (mysql+dind, etc.)
- [ ] Update profile generation scripts to use new templates
- [ ] Document port forwarding setup for when external access is needed
