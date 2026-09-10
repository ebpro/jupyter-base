# Testing

This document describes the current testing strategy for Solen and the post-install contract checks added for feature validation.

## Test layers

Solen testing is split into several layers:

1. **Static validation**
   - feature schema validation
   - profile generation
   - version synchronization
   - Python unit tests
   - linting

2. **Feature contract tests**
   - each feature can declare a `postInstallCheck`
   - generated Dockerfiles can run those checks during or after image build
   - checks are intended to verify that a feature is usable in the final container

3. **Feature test scripts**
   - features may include `*test*.sh` scripts
   - scripts are staged into the image under `/opt/solen/feature-tests/<feature>/`
   - `/opt/solen/run-feature-tests.sh` executes all staged feature tests

4. **CI build validation**
   - canonical builds run in GitHub Actions with Docker BuildKit
   - post-install checks can be enabled per build run

## Local setup

Create a virtual environment and install the CLI with development dependencies:

```bash
python3 -m venv .venv
.venv/bin/pip install --upgrade pip
.venv/bin/pip install -e 'solen-cli[dev]'
```

Optional, for local mypy checks:

```bash
.venv/bin/pip install types-PyYAML
```

## Static validation

Run these commands from the repository root:

```bash
.venv/bin/python -m pytest tests -q
.venv/bin/ruff check solen-cli tests
.venv/bin/solen validate features
.venv/bin/solen versions sync --check
```

Generate profiles locally:

```bash
.venv/bin/solen generate profiles --matrix profiles/matrix --out /tmp/generated-profiles --chain
```

For local work, prefer generating profiles into a temporary directory rather than directly into `generated/profiles/`.

## Unit tests

The `tests/` directory contains pytest-based validation for generator and feature contract helpers.

Current relevant tests include:

- `tests/test_postinstall_checks.py`
- `tests/test_postinstall_check_collection.py`

Run them with:

```bash
.venv/bin/python -m pytest tests -q
```

## Feature post-install checks

A feature can declare a post-install check in `feature.json`:

```json
{
  "id": "java-kernel",
  "postInstallCheck": {
    "command": "bash -lc '...'",
    "description": "Verify Java Jupyter kernelspec is registered"
  }
}
```

The generated Dockerfile embeds a runner at:

```text
/opt/solen/run-postinstall-checks.sh
```

Behavior:

- commands are base64-encoded to avoid shell escaping issues
- checks run as `${NB_USER:-jovyan}`
- the runner prefers `runuser`, then `setpriv`, then `su`
- all configured checks are executed
- the runner exits with the number of failed checks

The behavior is controlled by:

```dockerfile
ARG RUN_POSTINSTALL_CHECKS="false"
ENV RUN_POSTINSTALL_CHECKS="${RUN_POSTINSTALL_CHECKS}"
```

When enabled, the generated image also:

- runs per-feature post-install checks immediately after each feature install
- runs the full post-install check runner near the end of the install stage

## Feature test scripts

Features may include test scripts such as:

```text
features/java-kernel/test-java-kernel.sh
```

Conventions:

- use bash
- fail fast with `set -euo pipefail`
- verify the runtime artifacts that the feature is supposed to provide
- avoid assumptions about login-shell state where possible
- target the non-root user when relevant

Example:

```bash
#!/usr/bin/env bash
set -euo pipefail

java_bin="$(command -v java || true)"
if [ -z "$java_bin" ]; then
  java_bin="/home/${NB_USER:-jovyan}/.sdkman/candidates/java/current/bin/java"
fi

if [ ! -x "$java_bin" ]; then
  echo "ERROR: java runtime not found" >&2
  exit 1
fi

"$java_bin" -version
```

Generated images stage these scripts into:

```text
/opt/solen/feature-tests/<feature>/
```

and provide:

```text
/opt/solen/run-feature-tests.sh
```

To run all staged feature tests in a built image:

```bash
docker run --rm --entrypoint /opt/solen/run-feature-tests.sh <image>
```

## CI validation

### `ci-validate.yml`

The validation workflow runs static checks, including:

- `solen validate features`
- profile generation
- devcontainer generation
- version synchronization
- pytest
- ruff over `solen-cli` and `tests`

### `ci-build.yml`

The build workflow:

- generates profiles
- generates `generated/Dockerfile`
- generates `generated/docker-bake.hcl`
- builds the selected profiles
- optionally runs post-install checks in the built images

The post-install check gate is controlled by the workflow input:

```yaml
run-postinstall-checks:
  description: 'Run feature postInstallCheck commands in built images'
  required: false
  default: 'false'
  type: choice
  options:
    - 'true'
    - 'false'
```

When enabled, CI runs:

```bash
docker run --rm --entrypoint /opt/solen/run-postinstall-checks.sh <image>
```

for each built profile.

## Local limitations

Some validations are easier or only possible in CI:

- canonical image builds require Docker BuildKit and `docker buildx bake`
- feature runtime checks require the built image
- Java-related checks require a Java-enabled profile
- Jupyter/kernel checks require the relevant Python/Jupyter stack

If local Docker/BuildKit support is unavailable, rely on CI for image-level validation.

## Roadmap

Future testing work should extend the current slice with:

- E2E/BDD scenarios for full profile builds
- automated smoke tests for `quarto-full`
- optional SonarQube quality gates
- Harbor image admission checks
- public registry validation
- richer test reporting for CI artifacts
