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
   - post-install checks are armed on every build run (a manual dispatch can select `false` to skip)

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
- runs post-install checks in the built images

The post-install check gate is controlled by the workflow input:

```yaml
run-postinstall-checks:
  description: 'Run feature postInstallCheck commands in built images (select false to skip)'
  required: false
  default: 'true'
  type: choice
  options:
    - 'true'
    - 'false'
```

`workflow_run` and `pull_request` triggers carry no `event.inputs`, so the step's
`${{ github.event.inputs['run-postinstall-checks'] || 'true' }}` fallback arms them too;
only a manual dispatch that selects `'false'` skips the step.

When enabled, CI runs:

```bash
docker run --rm --entrypoint /opt/solen/run-postinstall-checks.sh <image>
```

for each built profile.

### `ci-publish.yml` — `verify-published`

Publishing re-runs the same contract **against the published artifact**. A `200` on a
registry manifest proves a tag exists, not that its content is correct; this job is what
closes that gap.

- `needs: [merge-index]` and **unguarded**, so it runs on every publish trigger
  (`develop` push, `v*` tag, dispatch) — unlike `sign-release`, which is gated by
  `if: startsWith(github.ref, 'refs/tags/v')`.
- For each enumerated `<tag>-amd64` image it asserts two independent things:
  1. `/opt/solen/run-postinstall-checks.sh` exits `0` — the per-feature contract already
     baked into the image, and
  2. a binary floor — `rsync`, `jq`, `cmake` all resolvable on `PATH` — which trusts
     neither the baked script nor the feature graph.
- amd64 only. The arm pool's runners also carry the bare `ebpro-org` label, so the job
  pins `[self-hosted, linux, x64, ebpro-org]`; with no binfmt by design, an `-amd64`
  image cannot be `docker run` on arm64.
- It refuses to pass vacuously: enumerating zero tags fails the job (a silent-skip is the
  exact defect class it exists to remove), and it accumulates failures instead of
  failing fast so one run reports the whole blast radius.
- It is a **leaf** job — nothing `needs` it, so a verification-harness hiccup cannot
  block signing.

#### Why publish does not just set `RUN_POSTINSTALL_CHECKS=true`

Setting the build arg at publish time looks like the cheaper way to get item 1 above, and
it was **rejected**. The template promotes the ARG straight to `ENV`
(`solen-cli/solen/generators/dockerfile_template.j2:97-98`), and that variable is consumed
by the feature-install `RUN` blocks (`:179`, `:193`, `:214`). Because the value lands in
the layer key, flipping it invalidates the heavy install layer and re-executes every
installer cold — an order-of-an-hour penalty on **every** publish, to check content that
`docker run` can check for free after the fact.

`tests/test_verify_published_contract.py` pins this decision (`RUN_POSTINSTALL_CHECKS`
must never appear in `ci-publish.yml`). If you are about to arm checks at publish time,
read that test first.

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
- Harbor image admission checks (published-GHCR-artifact validation already exists as
  `verify-published`; registry-side admission policy does not)
- richer test reporting for CI artifacts
