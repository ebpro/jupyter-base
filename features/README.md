# Feature Development Guide

This document describes best practices for creating and maintaining devcontainer features in this repository.

## Feature Structure

Each feature lives in `features/<feature-name>/` with:
- `feature.json` - metadata and options
- `install.sh` - installation script
- `files/` (optional) - additional files to copy

## Feature Dependencies

### Declaring Dependencies

**IMPORTANT**: All features must declare their dependencies explicitly using the `dependsOn` field in feature.json.

```json
{
  "id": "my-feature",
  "name": "My Feature",
  "description": "...",
  "dependsOn": ["python-conda", "user"],
  "options": { ... }
}
```

**Rules**:
1. **Required**: Use `dependsOn` array to list features that must be installed first
2. **Foundation features**: `user`, `_lib`, `python-base`, `git-lfs`, `gh-cli` have no dependencies
3. **Transitive**: Dependencies are automatically resolved (A→B→C means A needs C too)
4. **Automatic ordering**: The build system automatically sorts features by dependencies
5. **Validation**: Use `scripts/validate-feature-deps.py` to check for cycles and missing deps

**Example Dependencies**:
```json
// Feature that needs conda
{"dependsOn": ["python-conda"]}

// Feature that needs Java and Jupyter
{"dependsOn": ["java-devtools", "jupyter-kernels"]}

// Feature that needs user home directory
{"dependsOn": ["user"]}

// Foundation feature (no dependencies)
{"dependsOn": []}  // or omit the field
```

### Dependency Graph Visualization

See [DEPENDENCIES.md](DEPENDENCIES.md) for the complete dependency graph with Mermaid diagram.

**Quick Reference**:

**Core Features** (no dependencies):
- `user` - creates NB_USER
- `_lib` - shared helpers
- `python-base` - system Python
- Standalone tools: `git-lfs`, `gh-cli`, `kubernetes-tools`, `tilt`

**System Layer** (depends on: user):
- `base-apt` - core packages
- `zsh-config` - shell
- `prompt-helpers` - gitstatusd
- `startup` - init scripts
- `docker-cli-helper` - docker group
- `podman` - container runtime
- `jetbrains-gateway` - SSH server

**Python Stack**:
- `python-conda` (depends on: user)
  - `jupyter-kernels` (depends on: python-conda)
  - `pip-requirements` (depends on: python-conda)
  - `quarto` (depends on: python-conda)

**Java Stack**:
- `java-sdkman` (depends on: user)
  - `java-devtools` (depends on: java-sdkman)
    - `java-kernel` (depends on: java-devtools, jupyter-kernels)
  - `kotlin` (depends on: java-sdkman)
  - `graalvm` (depends on: java-sdkman)

**Node Stack**:
- `node` (depends on: user)
  - `lsp-tools` (depends on: node)
  - `code-server` (depends on: user, node)
    - `codeserver-extensions` (depends on: code-server)

**Build Tools** (depend on: base-apt):
- `dev-tools` - compilers
- `texlive` - LaTeX

### Validating Dependencies

Before committing changes to feature.json files, validate dependencies:

```bash
# Validate all features
python3 scripts/validate-feature-deps.py

# Validate a specific profile
python3 scripts/validate-feature-deps.py --profile profiles/20-02-quarto-lecture-dev-java-25
```

**What gets validated**:
- ✅ All dependencies reference existing features
- ✅ No circular dependencies (A→B→A)
- ✅ Topological sort produces valid installation order
- ✅ Profile feature ordering respects dependencies (when checking profiles)
- `texlive` → LaTeX (independent)

**Development Tools**:
- `node` → Node.js (independent)
- `lsp-tools` → Language servers (depends on: node, python-conda)
- `dev-tools` → jq, fd, ripgrep, etc. (independent)
- `code-server` → VS Code web (independent)

**Container Tools**:
- `docker-cli-helper` → Docker CLI (independent)
- `podman` → Podman (independent)
- `kubernetes-tools` → kubectl, helm (independent)
- `tilt` → Tilt (depends on: kubernetes-tools)

**Git Tools**:
- `git-lfs` → Git LFS (independent)
- `gh-cli` → GitHub CLI (independent)

**Shared Features**:
- `quarto-common` → Quarto templates/dirs (depends on: user)
- `prompt-helpers` → Shell prompts (depends on: zsh-config)
- `startup` → Init scripts (depends on: user)

### Ordering Rules

When creating profiles, order features from low-level to high-level:
1. User/system setup (user, base-apt, zsh-config)
2. Language runtimes (python-conda, java-sdkman, node)
3. Development tools (dev-tools, lsp-tools)
4. Application tools (quarto, jupyter-kernels, java-kernel)
5. Customizations (prompt-helpers, startup)

**Example Profile** (`profiles/20-02-quarto-lecture-dev-java-25`):
```
@parent:20-01-quarto-lecture
java-devtools
java-kernel
```

Parent chain resolves to:
```
user → base-apt → zsh-config → python-conda → jupyter-kernels → quarto → java-devtools → java-kernel
```

## Standard Variables

All features should use these standard variables:

```bash
NB_USER=${NB_USER:-jovyan}
NB_UID=${NB_UID:-1001}
NB_GID=${NB_GID:-1001}
HOME_DIR="/home/${NB_USER}"
CONDA_DIR="${CONDA_DIR:-${HOME_DIR}/miniforge3}"
```

## Installation Script Template

```bash
#!/usr/bin/env bash
set -euo pipefail

# Source shared helpers
if [ -n "${FEATURE_HELPERS_DIR:-}" ] && [ -f "${FEATURE_HELPERS_DIR}/helpers.sh" ]; then
  source "${FEATURE_HELPERS_DIR}/helpers.sh"
elif [ -f "../../../scripts/feature_helpers.sh" ]; then
  source "../../../scripts/feature_helpers.sh"
fi

# Standard variables
NB_USER=${NB_USER:-jovyan}
NB_UID=${NB_UID:-1001}
NB_GID=${NB_GID:-1001}
HOME_DIR="/home/${NB_USER}"

# Ensure user directories exist
if command -v fh_ensure_user_dirs >/dev/null 2>&1; then
  fh_ensure_user_dirs "${NB_USER}" "${NB_UID}" "${NB_GID}" || true
else
  mkdir -p "${HOME_DIR}/.local/bin" "${HOME_DIR}/.cache" || true
  chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/.local" "${HOME_DIR}/.cache" || true
fi

fh_log "Installing my-feature..."

# Your installation logic here

# Mark feature as installed
feature_mark_installed

fh_log "my-feature installation complete"
```

## Best Practices

### 1. Version Pinning
Always pin versions explicitly:
```bash
TOOL_VERSION=$(resolve_version "tool")  # From Artefacts/versions.json
# NOT: curl latest-url
```

### 2. Error Handling
Use `set -euo pipefail` and handle errors explicitly:
```bash
if ! command -v tool >/dev/null 2>&1; then
  fh_log "tool not found, installing..."
fi
```

### 3. Idempotency
Features should be safe to run multiple times:
```bash
if feature_is_installed; then
  fh_log "Feature already installed, skipping"
  exit 0
fi
```

### 4. Ownership
Always ensure correct ownership for user files:
```bash
chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/.config/tool" || true
```

### 5. Cleanup
Clean up temporary files and caches:
```bash
rm -rf /tmp/install-*.sh
apt-get clean
rm -rf /var/lib/apt/lists/*
```

### 6. Logging
Use helper functions for consistent output:
```bash
fh_log "Step 1: downloading..."
fh_log "Step 2: extracting..."
```

## Testing Your Feature

### Local Testing
```bash
# Generate and build a test profile
./build.sh --profile 00-01-minimal --generate-only
docker build -f Dockerfile.generated --target profile-00-01-minimal -t test .

# Run and verify
docker run --rm test bash -c "your-tool --version"
```

### Post-Install Checks
Add validation to feature.json:
```json
{
  "postInstallCheck": {
    "command": "your-tool --version && test -f /path/to/config",
    "description": "Verify tool is installed and configured"
  }
}
```

## Common Patterns

### Installing from GitHub Releases
```bash
TOOL_VERSION=$(resolve_version "tool")
TOOL_URL="https://github.com/org/tool/releases/download/v${TOOL_VERSION}/tool-${ARCH}.tar.gz"
TOOL_CHKSUM=$(resolve_checksum "tool" "${TOOL_VERSION}" "${ARCH}")

curl -fsSL "${TOOL_URL}" -o /tmp/tool.tar.gz
echo "${TOOL_CHKSUM}  /tmp/tool.tar.gz" | sha256sum -c -
tar -xzf /tmp/tool.tar.gz -C /opt
```

### Running Commands as Non-Root User
```bash
su - ${NB_USER} -s /bin/bash -c "conda install -y package"
# or with a script
cat > /tmp/user-install.sh <<'EOF'
#!/bin/bash
set -euo pipefail
conda install -y package
EOF
chmod +x /tmp/user-install.sh
su - ${NB_USER} -s /bin/bash -c /tmp/user-install.sh
```

### Adding to PATH
```bash
# System-wide (all users)
mkdir -p /etc/profile.d
cat > /etc/profile.d/tool.sh <<EOF
export PATH="/opt/tool/bin:\$PATH"
export TOOL_HOME="/opt/tool"
EOF

# User-specific
if ! grep -q '/opt/tool/bin' "${HOME_DIR}/.zshrc" 2>/dev/null; then
  echo 'export PATH="/opt/tool/bin:$PATH"' >> "${HOME_DIR}/.zshrc"
fi
```

## Troubleshooting

### Feature fails with "unbound variable"
- Ensure all variables are set with defaults: `VAR=${VAR:-default}`
- Check that sourcing helpers succeeded
- Use `set +u` temporarily if needed for optional variables

### Ownership errors at runtime
- Ensure you chowned user directories during install
- Run user-specific installs as `NB_USER`, not root
- Check that `HOME_DIR` is correctly set

### Feature runs but doesn't work
- Add `postInstallCheck` to validate
- Test in a clean container
- Check logs: `docker logs <container>`

## Contributing

When adding a new feature:
1. Copy the template above
2. Update this dependency graph
3. Add to an appropriate profile for testing
4. Submit PR with description and test results

## Resources

- [DevContainer Feature Spec](https://containers.dev/implementors/features/)
- [Docker Best Practices](https://docs.docker.com/develop/dev-best-practices/)
- [Bash Strict Mode](http://redsymbol.net/articles/unofficial-bash-strict-mode/)
