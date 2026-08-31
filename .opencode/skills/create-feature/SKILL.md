---
name: create-feature
description: Create a new devcontainer feature for solen (jupyter-base). Use when adding features, scaffolding feature.json and install.sh, or creating bundles. Triggers on "new feature", "add feature", "create feature".
---

# Create DevContainer Feature

Creates a new devcontainer feature following solen project conventions.

## Workflow

### Step 1: Gather Requirements (Interactive)

Ask the user for details. Use `question` tool or infer from context. Propose smart defaults:

**Questions to ask (with defaults in parens):**
1. Feature name (kebab-case, e.g. `cargo-cli`, `rust-analyzer`)
2. Feature type: [tool download (default) / system packages / bundle / library (_lib) / service]
3. What does it install? (description)
4. Dependencies - ask to pick from existing features. Defaults by type:
   - **Tool download**: `container-user`, `_lib/download-release`
   - **System packages**: `container-user`, `system-essentials`
   - **Bundle**: list of features (user provides)
   - **Library**: none
   - **Service**: `container-user`
5. Binary names it provides (e.g. `cargo`, `rustc`) -- for tool/service types
6. Version to pin (if "latest", check online for current release)
7. Platforms: [linux/amd64 + linux/arm64 (default) / linux/amd64 only / linux/arm64 only]
8. VSCode extensions to recommend (if any)
9. Post-install verify command (e.g. `cargo --version`)

### Step 2: Generate feature.json

Create `.devcontainer/features/<name>/feature.json`:

**Template for tool download feature:**
```json
{
  "id": "<name>",
  "name": "<Name> Tool",
  "version": "0.1.0",
  "description": "<description>",
  "documentationURL": "<tool-docs-url>",
  "maintainer": {"name":"Emmanuel BRUNO","email":"emmanuel.bruno@univ-tln.fr"},
  "dependsOn": ["container-user", "_lib/download-release"],
  "options": {
    "version": {
      "type": "string",
      "default": "<detected-latest-version>",
      "description": "<tool> version to install"
    }
  },
  "provides": ["<binary1>", "<binary2>"],
  "postInstallCheck": {
    "command": "<verify-command>",
    "description": "Verify <name> is installed"
  },
  "platforms": ["linux/amd64", "linux/arm64"],
  "vscode": {
    "extensions": []
  }
}
```

**Template for system package feature:**
```json
{
  "id": "<name>",
  "name": "<Name>",
  "version": "0.1.0",
  "description": "<description>",
  "dependsOn": ["container-user", "system-essentials"],
  "options": {},
  "provides": ["<packages>"],
  "postInstallCheck": {
    "command": "<verify-command>",
    "description": "Verify <name> is installed"
  },
  "platforms": ["linux/amd64", "linux/arm64"]
}
```

**Template for bundle (meta-feature, no install.sh):**
```json
{
  "id": "bundle-<name>",
  "name": "Bundle <Name>",
  "version": "0.1.0",
  "description": "<description>",
  "maintainer": {"name":"Emmanuel BRUNO","email":"emmanuel.bruno@univ-tln.fr"},
  "dependsOn": [
    "<feature1>",
    "<feature2>"
  ],
  "platforms": ["linux/amd64", "linux/arm64"]
}
```

**Template for library (_lib/):**
```json
{
  "id": "_lib/<name>",
  "name": "Lib <Name>",
  "version": "0.1.0",
  "description": "Shared helper: <what it provides>",
  "maintainer": {"name":"Emmanuel BRUNO","email":"emmanuel.bruno@univ-tln.fr"},
  "dependsOn": [],
  "platforms": ["linux/amd64", "linux/arm64"]
}
```

Rules:
- Always include `id` and `name` fields
- `dependsOn` must list real, existing features only
- For bundles: name must start with `bundle-`, no install.sh needed
- For libraries: directory must be under `_lib/`, provide shared functions
- `provides` lists actual binary names available on PATH after install
- `postInstallCheck.command` should be a one-liner that exits 0 on success

### Step 3: Generate install.sh (skip for bundles)

Create `.devcontainer/features/<name>/install.sh` (chmod +x):

**Template for tool download (using _lib/download-release):**
```bash
#!/usr/bin/env bash
# Source shared feature helpers
if [ -n "${FEATURE_HELPERS_DIR:-}" ] && [ -f "${FEATURE_HELPERS_DIR}/helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "${FEATURE_HELPERS_DIR}/helpers.sh"
elif [ -f "../../../scripts/feature_helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "../../../scripts/feature_helpers.sh"
fi
set -euo pipefail

# Source download helper
if [ -f "/usr/local/lib/download-release-helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "/usr/local/lib/download-release-helpers.sh"
else
  echo "ERROR: <name>: download-release helper not found"
  exit 1
fi

# Ensure per-user local/cache dirs exist
if command -v fh_ensure_user_dirs >/dev/null 2>&1; then
  fh_ensure_user_dirs "${NB_USER:-jovyan}" "${NB_UID:-1001}" "${NB_GID:-1001}" || true
else
  HOME_DIR=${HOME_DIR:-/home/${NB_USER:-jovyan}}
  mkdir -p "${HOME_DIR}/.local/bin" "${HOME_DIR}/.cache" >/dev/null 2>&1 || true
  chown -R ${NB_UID:-1001}:${NB_GID:-1001} "${HOME_DIR}/.local" "${HOME_DIR}/.cache" >/dev/null 2>&1 || true
fi

NB_USER=${NB_USER:-jovyan}
NB_UID=${NB_UID:-1001}
NB_GID=${NB_GID:-1001}
HOME_DIR="/home/${NB_USER}"
LOCAL_BIN="${HOME_DIR}/bin"
mkdir -p "${LOCAL_BIN}"

echo "===================================================================="
echo "Feature: <name>"
echo "===================================================================="

# Resolve version from Artefacts
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
resolve_version() {
  local tool="$1" v=""
  for json_file in "${SOURCE_DIR}/../../Artefacts/versions.json" "/tmp/Artefacts/versions.json" "/tmp/versions.json"; do
    if [ -f "$json_file" ]; then
      v=$(jq -r --arg t "$tool" '.tools[$t] // empty' "$json_file" 2>/dev/null || true)
      [ -n "$v" ] && { echo "$v"; return 0; }
    fi
  done
  echo ""
}

TOOL_VERSION=$(resolve_version "<tool>")
if [ -z "$TOOL_VERSION" ]; then
  echo "WARNING: <tool> version not found in Artefacts/versions.json, using default"
  TOOL_VERSION="<default-version>"
fi

echo "Installing <tool> version: ${TOOL_VERSION}"

# Resolve architecture
if command -v _map_architecture >/dev/null 2>&1; then
  ARCH=$(_map_architecture)
else
  ARCH=$(case "$(uname -m)" in x86_64|X86_64) echo "amd64" ;; aarch64|arm64) echo "arm64" ;; *) echo "amd64" ;; esac)
fi

# Download and install (ADAPT THIS SECTION per tool's release format)
# Example using GitHub releases:
# download_github_release "owner/repo" "binary-name" "${TOOL_VERSION}" "${LOCAL_BIN}" "filename-${TOOL_VERSION}-${ARCH}.tar.gz"

# Or direct binary download:
# curl -fsSL "https://dl.example.com/tool/${TOOL_VERSION}/tool-${ARCH}.tar.gz" | tar -xz -C "${LOCAL_BIN}"

# Set ownership
chown -R "${NB_UID}:${NB_GID}" "${LOCAL_BIN}" 2>/dev/null || true

echo "SUCCESS: <name> installed"
echo "<name>: done"
```

**Template for system packages (apt):**
```bash
#!/usr/bin/env bash
if [ -n "${FEATURE_HELPERS_DIR:-}" ] && [ -f "${FEATURE_HELPERS_DIR}/helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "${FEATURE_HELPERS_DIR}/helpers.sh"
elif [ -f "../../../scripts/feature_helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "../../../scripts/feature_helpers.sh"
fi
set -euo pipefail

if command -v fh_ensure_user_dirs >/dev/null 2>&1; then
  fh_ensure_user_dirs "${NB_USER:-jovyan}" "${NB_UID:-1001}" "${NB_GID:-1001}" || true
fi

echo "===================================================================="
echo "Feature: <name>"
echo "===================================================================="

if command -v apt_install >/dev/null 2>&1; then
  apt_install <package1> <package2>
else
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends <package1> <package2>
  rm -rf /var/lib/apt/lists/*
fi

echo "<name>: done"
```

**Template for library (_lib/):**
```bash
#!/usr/bin/env bash
set -euo pipefail

# Library features provide shared functions sourced by other features.
# Create the helper script that will be available at /usr/local/lib/<name>-helpers.sh

LIB_DIR="/usr/local/lib"
mkdir -p "${LIB_DIR}"

cat > "${LIB_DIR}/<name>-helpers.sh" << 'LIBEOF'
#!/usr/bin/env bash
# Auto-generated helper functions for <name>

# Add your functions here, following fh_ naming convention:
# eh_<function_name>() { ... }
# export -f eh_<function_name>

LIBEOF

chmod +x "${LIB_DIR}/<name>-helpers.sh"
echo "_lib/<name>: done"
```

### Step 4: Check Version and Add to Artefacts

1. **Check online for latest version** using `webfetch` on GitHub releases API or project site:
```
https://api.github.com/repos/owner/repo/releases/latest  --> tag_name
https://api.github.com/repos/owner/repo/tags?per_page=1  --> [0].name
```

2. **Add to Artefacts/versions.json** if not already present:
```json
// Add to .tools section:
{
  "tools": {
    "neovim": "0.10.0",
    "<tool>": "<latest-version>"
  }
}
```

3. **Update checksums if using pre-downloaded binaries:**
   - If the tool will be pre-cached via toolcache, add entry to `Artefacts/checksums.json`
   - Use `scripts/update-checksums.sh <tool>` to compute and add checksums
   - Or manually: download binary, compute sha256sum, add to JSON

### Step 5: Validate the Feature

Run validation to ensure the feature integrates properly:

```bash
# 1. Check feature.json is valid JSON
jq . .devcontainer/features/<name>/feature.json

# 2. Check shell script syntax
bash -n .devcontainer/features/<name>/install.sh

# 3. Check dependencies exist (run the validator)
python3 scripts/validate-feature-deps.py

# 4. Check helper sourcing is present (or inject it)
if ! grep -q 'FEATURE_HELPERS_DIR' .devcontainer/features/<name>/install.sh; then
  bash scripts/inject_prebaked_helpers.sh
fi
```

### Step 6: Test the Feature

Build a minimal test image and run the feature's postInstallCheck:

```bash
# Build test image for this single feature
bash scripts/test-feature.sh <name> --build-first

# Or run smoke test on built image (if already built as part of a profile)
bash scripts/test-profile.sh "<image-tag>" "<profile-name>"
```

### Step 7: Final Checklist

Verify before presenting to user:
- [ ] feature.json is valid JSON
- [ ] install.sh passes `bash -n` syntax check
- [ ] install.sh has helper sourcing snippet
- [ ] install.sh has fh_ensure_user_dirs call
- [ ] DependsOn features actually exist
- [ ] Version in feature.json options matches Artefacts/versions.json
- [ ] postInstallCheck command is meaningful
- [ ] provides list matches actual binaries

### Quick Reference: Existing Features Available as Dependencies

Core: `container-user`, `system-essentials`, `zsh-config`, `prompt-helpers`, `container-init`, `python-base`
Dev Tools: `gh`, `git-lfs`, `docker-cli`, `build-essentials`
Runtimes: `node`, `python-conda`, `java-jdk`, `java-sdkman`
Containers: `kubernetes-client`, `kubernetes-dev`, `podman`
Data: `mysql-client`, `postgresql-client`, `mongodb-client`, `redis-client`
Quarto: `quarto-cli`, `quarto-python`, `quarto-chromium`, `quarto-common`
Java: `java-maven`, `java-gradle`, `java-kernel`, `kotlin`, `graalvm`
Web: `typescript`, `react-tools`
ML: `ml-python-packages`
Remote IDE: `code-server`, `codeserver-extensions`, `jetbrains-gateway`
Other: `tilt`, `texlive`, `pip-requirements`, `container-init`, `jupyter-base`, `jupyter-kernels`, `container-user`
Libraries: `_lib/download-release`, `_lib/toolcache`, `_lib/checksum-verify`

### Common Tool GitHub Repos (for download scripts)

| Tool | GitHub Repo | Binary Pattern |
|------|-------------|----------------|
| gh | cli/cli | `gh_{version}_linux_{arch}.tar.gz` |
| kubectl | kubernetes/kubernetes | `kubectl-linux-{arch}` |
| helm | helm/helm | `helm-v{version}-linux-{arch}.tar.gz` |
| k9s | derailed/k9s | `k9s_Linux_{arch}.tar.gz` |
| kustomize | kubernetes-sigs/kustomize | `kustomize_{version}_linux_{arch}.tar.gz` |
| cargo/rustc | rust-lang/rustup (special) | Use rustup-init |
| node | nodejs/node | `node-v{version}-linux-{arch}.tar.xz` |
| tilt | tilt-dev/tilt | `tilt.{arch}.linux` |
| quarto | quarto-dev/quarto-cli | `quarto-{version}-linux-{arch}.tar.gz` |
| miniforge | conda-forge/miniforge | `Miniforge3-{version}-Linux-{arch}.sh` |
| golang | golang/go | `go{version}.linux-{arch}.tar.gz` |
| rust | rust-lang/rust | Via rustup |
| lazygit | jesseduffield/lazygit | `lazygit_{version}_linux_{arch}.tar.gz` |
| zoxide | superfly/zoxide | `zoxide-{version}-x86_64-unknown-linux-gnu.tar.gz` |
| eza | eza-community/eza | `eza_{version}_x86_64-unknown-linux-musl.tar.gz` |
| starship | starship/starship | `starship-{arch}-unknown-linux-gnu.tar.gz` |
