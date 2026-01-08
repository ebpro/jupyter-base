# Feature Architecture Analysis - Comprehensive Review

**Date:** 2025-12-19
**Scope:** All 46 features in `.devcontainer/features/`
**Context:** Identifying overlaps, monolithic features, unclear responsibilities, and architectural issues

---

## Executive Summary

After analyzing all 46 features, I've identified **significant architectural issues** similar to (and worse than) the Java feature problems:

**Critical Issues Found:**
1. ❌ **Massive monolithic features**: `quarto` (335 lines), `prompt-helpers` (228 lines), `python-conda` (225 lines)
2. ❌ **Database features installing Python dependencies**: Creates circular dependencies
3. ❌ **Redundant bundle features**: 12 bundle features with minimal value
4. ❌ **Inconsistent version management**: Some hardcoded, some from Artefacts
5. ⚠️ **Meta-features with duplicate logic**: `java-devtools` duplicates JDK installation

---

## 1. Python Ecosystem (5 features)

### Current structure:
```
python-base (39 lines)
├── pip-requirements (56 lines)
python-conda (225 lines) [SEPARATE TREE]
├── jupyter-kernels (105 lines)
└── ml-python-packages (13 lines)
```

### What each provides:
- **python-base**: System Python3 + pip via apt (39 lines)
- **python-conda**: Miniforge3 installation with complex version resolution, arch detection, checksum verification (225 lines)
- **pip-requirements**: Installs from `/tmp/requirements.txt` if present (56 lines)
- **jupyter-kernels**: Installs zsh/bash kernels, complex conda/mamba/pip fallback logic (105 lines)
- **ml-python-packages**: Conda installs 6 ML packages (13 lines)

### Issues identified:

1. ❌ **Two separate Python installations**: `python-base` vs `python-conda` are independent
   - No coordination between system Python and conda
   - `pip-requirements` depends on `python-base` but most profiles use `python-conda`

2. ❌ **Monolithic python-conda**: 225 lines doing too much
   - Version resolution (50+ lines)
   - Architecture detection (30+ lines)
   - Download + install (40+ lines)
   - Conda activation setup (30+ lines)
   - User permission handling (20+ lines)

3. ⚠️ **jupyter-kernels complexity**: 105 lines with complex fallback logic
   - Tries mamba → conda → pip → su pip
   - Each path duplicated for zsh and bash kernels
   - Could fail silently in multiple places

4. ⚠️ **ml-python-packages too simplistic**: Just runs raw `conda install`
   - No error handling
   - No user context switching
   - Inconsistent with jupyter-kernels approach

5. ❌ **Unclear relationship**: Which Python do features actually use?
   - `pip-requirements` → system Python
   - `jupyter-kernels` → conda Python
   - `ml-python-packages` → conda Python
   - No clear declaration

### Recommendation: **B** - Refactor with clear separation

**Proposed structure:**
```
python-system (simple apt install)
python-conda-base (just miniforge3 install)
├── python-conda-config (activation, .condarc)
├── pip-tools (unified pip installer for both)
jupyter-kernel-bash
jupyter-kernel-zsh
ml-packages (better error handling)
```

**Benefits:**
- Clear system vs conda separation
- Better caching (conda config changes don't invalidate base)
- Simpler feature logic (each <100 lines)
- Reusable kernel installers

---

## 2. Database Clients (4 features)

### Current structure:
```
base-apt
├── postgresql-client (118 lines)
├── mysql-client (100 lines)
├── mongodb-client (15 lines)
└── redis-client (8 lines)
```

### What each provides:
- **postgresql-client**: Adds PG APT repo, installs client tools, pgcli via pip, libpq-dev (118 lines)
- **mysql-client**: Installs mysql-client/mariadb-client, mycli via pip, libmysqlclient-dev (100 lines)
- **mongodb-client**: Adds MongoDB repo, installs mongosh + database-tools (15 lines)
- **redis-client**: Simple apt install of redis-tools (8 lines)

### Issues identified:

1. ❌ **Database features installing Python packages**: MAJOR ISSUE
   ```bash
   # postgresql-client/install.sh
   if [ "${INSTALL_PGCLI}" = "true" ]; then
       pip3 install --no-cache-dir pgcli
   fi

   # mysql-client/install.sh
   if [ "${INSTALL_MYCLI}" = "true" ]; then
       pip3 install --no-cache-dir mycli
   fi
   ```
   - Creates hidden dependency on Python
   - Not declared in `dependsOn`
   - Can fail if Python not available

2. ❌ **Mixing concerns**: Client tools + dev libraries + enhanced CLIs
   - `libpq-dev` in postgresql-client
   - `libmysqlclient-dev` in mysql-client
   - These are compilation dependencies, not client tools

3. ⚠️ **Inconsistent complexity**:
   - postgresql: 118 lines (repo setup + pip install)
   - mysql: 100 lines (similar)
   - mongodb: 15 lines (simpler repo setup)
   - redis: 8 lines (trivial apt install)

4. ⚠️ **Repository management in features**:
   - postgresql and mysql add custom APT repos
   - Should be abstracted or cached
   - Slows builds when repos are flaky

### Recommendation: **A** - Split into base + enhanced

**Proposed structure:**
```
postgresql-client-base (core tools only, ~30 lines)
├── postgresql-dev (libpq-dev)
└── postgresql-enhanced (pgcli - depends on python-base)

mysql-client-base (core tools only, ~30 lines)
├── mysql-dev (libmysqlclient-dev)
└── mysql-enhanced (mycli - depends on python-base)

mongodb-client (fine as-is)
redis-client (fine as-is)
```

**Benefits:**
- Base features are pure client tools (fast, no Python dependency)
- Enhanced CLIs declare Python dependency explicitly
- Dev libraries separate for better caching
- Users can choose what they need

---

## 3. Node/Web Ecosystem (4 features)

### Current structure:
```
user
└── node (36 lines)
    ├── lsp-tools (29 lines)
    ├── typescript (7 lines)
    └── react-tools (7 lines)
```

### What each provides:
- **node**: Volta or apt nodejs/npm (36 lines)
- **lsp-tools**: Installs pyright via npm (29 lines)
- **typescript**: `npm install -g typescript @types/node` (7 lines)
- **react-tools**: `npm install -g vite create-next-app create-react-app` (7 lines)

### Issues identified:

1. ⚠️ **lsp-tools misnamed**: Only installs pyright (Python LSP)
   - Should be `python-lsp` or `pyright`
   - Name implies multiple LSP servers
   - Actually only does 1 thing

2. ❌ **Global npm installs in features**: Anti-pattern
   ```bash
   npm install -g vite create-next-app create-react-app
   ```
   - These are project scaffolding tools
   - Should use `npx` at project creation time
   - Pinning globally breaks reproducibility

3. ⚠️ **Missing LSP servers**: Named `lsp-tools` but only has pyright
   - No typescript-language-server
   - No eslint_d
   - No prettier
   - Misleading name for single tool

4. ✅ **Node feature is good**: Clear choice between Volta and apt
   - Good documentation of options
   - Reasonable size

### Recommendation: **B** - Rename and fix scope

**Proposed structure:**
```
node-runtime (base Node.js only)
├── pyright (rename from lsp-tools)
├── typescript-dev (tsc + ts-node, not scaffolders)
└── node-scaffolders (optional: vite, cra - with warning)
```

**Benefits:**
- Clear naming (`pyright` does what it says)
- Typescript dev tools separate from scaffolders
- Discourages global scaffolder installs
- Can add real multi-LSP feature later

---

## 4. Container Tools (4 features)

### Current structure:
```
user
├── podman (40 lines)
├── docker-cli-helper (45 lines)
└── tilt (88 lines)

kubernetes-tools (149 lines) [INDEPENDENT]
```

### What each provides:
- **podman**: Apt install of podman (40 lines)
- **docker-cli-helper**: Creates docker group, adds user, socket checker (45 lines)
- **tilt**: Complex install with toolcache, version resolution, arch detection (88 lines)
- **kubernetes-tools**: Installs kubectl, helm, k9s, kustomize, minikube with version pinning (149 lines)

### Issues identified:

1. ❌ **kubernetes-tools is monolithic**: 149 lines doing too much
   - Installs 5 different tools
   - Each has version resolution
   - Each has arch detection
   - Each has download + install logic
   - Violates Single Responsibility

2. ⚠️ **docker-cli-helper doesn't install docker**: Misleading name
   - Only sets up group membership
   - Should be `docker-group-setup` or similar

3. ⚠️ **No docker CLI install**: Missing feature
   - Users need docker CLI for docker commands
   - Must rely on host Docker Desktop

4. ✅ **podman is simple**: Good focused feature

5. ⚠️ **tilt complexity**: 88 lines for single binary
   - Uses toolcache (good)
   - Could be template for other tools

### Recommendation: **A** - Split kubernetes-tools

**Proposed structure:**
```
kubectl (standalone)
helm (standalone)
k9s (standalone)
kustomize (optional)
minikube (optional)

docker-group-helper (rename docker-cli-helper)
podman (fine as-is)
tilt (fine as-is, maybe extract pattern)
```

**Benefits:**
- Each k8s tool can be cached independently
- Users can install only what they need
- Clear responsibilities
- Better layer caching (kubectl changes don't invalidate helm)

---

## 5. Editor/IDE (3 features)

### Current structure:
```
user
└── node
    └── code-server (92 lines)
        └── codeserver-extensions (41 lines)

user
└── jetbrains-gateway (67 lines)
```

### What each provides:
- **code-server**: Downloads and installs code-server binary with version resolution (92 lines)
- **codeserver-extensions**: Reads `/tmp/codeserver_extensions` file, doesn't actually install (41 lines)
- **jetbrains-gateway**: Installs openssh-server, configures sshd for remote JetBrains access (67 lines)

### Issues identified:

1. ❌ **codeserver-extensions doesn't install extensions**: Misleading
   ```bash
   echo "codeserver-extensions: would install extension $ext (requires code-server CLI at runtime)"
   # Note: WOULD install, not DOES install
   ```
   - Just reads file and logs
   - Actual install must happen at runtime
   - Feature is essentially a no-op

2. ⚠️ **jetbrains-gateway scope creep**: More than gateway
   - Installs and configures sshd
   - Creates startup scripts
   - Should be `remote-ssh-server` or similar
   - Gateway is just one consumer

3. ✅ **code-server is reasonable**: Good version management
   - Clear responsibility
   - Uses Artefacts versions

### Recommendation: **C** - Minor fixes

**Proposed structure:**
```
code-server (fine as-is)
code-server-extensions (fix to actually install or document clearly)
ssh-server (rename jetbrains-gateway)
```

**Benefits:**
- Clear expectations (ssh-server is generic)
- Fix extensions or make runtime-only clear
- Keep existing structure mostly intact

---

## 6. Shell/Environment (4 features)

### Current structure:
```
user (45 lines) [ROOT]
├── zsh-config (103 lines)
├── prompt-helpers (228 lines) [MONOLITHIC]
└── startup (44 lines)
```

### What each provides:
- **user**: Creates jovyan user, sets up sudo, home directories (45 lines)
- **zsh-config**: Installs prezto, creates .zshrc symlinks (103 lines)
- **prompt-helpers**: Installs gitstatusd with complex version/arch/checksum resolution (228 lines)
- **startup**: Installs run-startup-scripts helper (44 lines)

### Issues identified:

1. ❌ **prompt-helpers is MASSIVELY monolithic**: 228 lines!
   - Version resolution (40 lines)
   - Arch detection (30 lines)
   - Checksum resolution (30 lines)
   - Toolcache logic (50 lines)
   - Local artefact handling (30 lines)
   - Download + install (30 lines)
   - All for installing ONE BINARY (gitstatusd)

2. ⚠️ **zsh-config couples prezto**: What about oh-my-zsh users?
   - Hardcoded to prezto
   - Should be `zsh-prezto` or make framework configurable

3. ⚠️ **startup is vague**: What scripts does it run?
   - Just copies a file
   - Actual startup logic elsewhere

4. ✅ **user feature is good**: Core user setup, reasonable size

### Recommendation: **A** - Extract patterns, simplify

**Proposed structure:**
```
user (fine as-is)
zsh-prezto (rename from zsh-config)
gitstatus (extract from prompt-helpers, use shared installer pattern)
startup-scripts (keep as-is but improve docs)
```

**Benefits:**
- `gitstatus` is clear and focused
- Can create other prompt helpers later
- Prezto naming is explicit
- Extract common binary installer pattern for reuse

---

## 7. Build/Dev Tools (4 features)

### Current structure:
```
user
└── base-apt (40 lines)
    └── dev-tools (33 lines)

gh-cli (125 lines)
git-lfs (49 lines)
```

### What each provides:
- **base-apt**: Reads `/tmp/Artefacts/apt_packages_base`, installs via apt (40 lines)
- **dev-tools**: Installs build-essential, cmake, pkg-config, python3-dev, monitoring tools (33 lines)
- **gh-cli**: Complex install with version resolution, toolcache, arch detection (125 lines)
- **git-lfs**: Simple apt install + user initialization (49 lines)

### Issues identified:

1. ⚠️ **base-apt is generic indirection**: Reads external file
   - Flexibility is good
   - But makes feature opaque
   - Can't see what's installed from feature.json

2. ⚠️ **dev-tools mixes build + monitoring**: Unclear scope
   - build-essential, cmake, pkg-config = build tools ✓
   - htop, lsof, strace = monitoring/debugging tools ✗
   - Should split

3. ⚠️ **gh-cli complexity**: 125 lines for single binary
   - Similar pattern to tilt, gitstatus
   - Should extract shared installer pattern

4. ✅ **git-lfs is good**: Simple, clear, does one thing

### Recommendation: **B** - Split dev-tools

**Proposed structure:**
```
base-apt (keep for flexibility)
build-tools (build-essential, cmake, pkg-config)
dev-monitoring (htop, lsof, strace)
gh-cli (extract common installer pattern)
git-lfs (fine as-is)
```

**Benefits:**
- Clear separation of concerns
- Build tools vs runtime tools
- Can cache independently
- Extract reusable binary installer pattern

---

## 8. Document Authoring (3 features)

### Current structure:
```
user
└── python-conda
    └── quarto (335 lines) [MASSIVE MONOLITH]
        └── quarto-common (44 lines)

base-apt
└── texlive (158 lines)
```

### What each provides:
- **quarto**: MASSIVE complex install - version resolution, arch detection, toolcache, checksum, TinyTeX, Python packages, R packages (335 lines!)
- **quarto-common**: Creates directory structure, copies templates (44 lines)
- **texlive**: Installs TinyTeX with version resolution, gated by `/tmp/TeXLive` flag file (158 lines)

### Issues identified:

1. ❌ **quarto is THE WORST OFFENDER**: 335 lines!
   - Version resolution (50 lines)
   - Arch detection (30 lines)
   - Checksum resolution (40 lines)
   - Toolcache logic (50 lines)
   - Quarto binary install (50 lines)
   - Python package installs (40 lines)
   - R package installs (30 lines)
   - Template handling (20 lines)
   - Configuration setup (25 lines)
   - Doing EVERYTHING in one feature

2. ❌ **quarto installs Python packages**: Scope creep
   ```bash
   pip3 install jupyter nbconvert nbformat
   ```
   - Should depend on python features
   - Not declare dependency in feature.json

3. ❌ **quarto installs R packages**: Even more scope creep
   - R not even declared as dependency
   - Assumes R available

4. ⚠️ **texlive gating is weird**: Requires `/tmp/TeXLive` file
   - Silent skip if missing
   - Unclear why this pattern exists

5. ⚠️ **quarto-common is fine**: Does directory setup, reasonable

### Recommendation: **A** - URGENT: Split quarto immediately

**Proposed structure:**
```
quarto-binary (just the quarto CLI install)
├── quarto-config (configuration files)
├── quarto-templates (directory setup from quarto-common)
├── quarto-python (Python package dependencies - depends on python-base)
├── quarto-r (R package dependencies - depends on r-base)
└── texlive (keep separate, improve gating logic)
```

**Benefits:**
- quarto-binary < 80 lines (just binary install)
- Clear dependency declarations
- Can install quarto without Python/R packages
- Better caching (config changes don't invalidate binary)
- Each piece independently testable

---

## 9. Java Ecosystem (8 features) - PREVIOUS ANALYSIS

### Current structure:
```
user
└── java-sdkman (89 lines)
    ├── java-jdk (127 lines)
    ├── java-maven (56 lines)
    ├── java-gradle (56 lines)
    ├── kotlin (27 lines)
    ├── graalvm (29 lines)
    ├── java-devtools (167 lines) [META]
    └── java-kernel (133 lines)
```

### Issues identified (from previous analysis):

1. ❌ **java-devtools duplicates java-jdk**: 167 lines of duplicate JDK install logic
2. ⚠️ **java-kernel is complex**: 133 lines with download logic
3. ✅ **java-maven, java-gradle are good**: Simple SDKMAN wrappers
4. ⚠️ **graalvm conflicts with java-jdk**: Need better handling

### Recommendation: **Already documented** - see previous analysis

---

## 10. Bundle Features (12 features)

### Current structure:
```
bundle-base-full
bundle-containers
bundle-data-science
bundle-db-multi
bundle-dev-base
bundle-java-build
bundle-java-db
bundle-k8s
bundle-ml-teaching
bundle-python-db
bundle-quarto-base
bundle-quarto-full
bundle-remote-ide
bundle-web-dev
```

### What each provides:
All bundles are just dependency aggregators (5 lines each):
```bash
#!/bin/bash
set -e
echo "Bundle: installed via dependsOn"
```

### Issues identified:

1. ⚠️ **Minimal value**: Just dependency lists
   - No actual installation logic
   - Could be replaced by better profiles
   - Each bundle forces a separate layer

2. ⚠️ **Naming inconsistency**:
   - `bundle-db-multi` vs `bundle-python-db` (plural vs singular)
   - `bundle-k8s` vs `bundle-containers` (abbreviated vs full)

3. ❌ **bundle-java-db is oddly specific**: Why this combination?
   - JDK + Maven + Gradle + PostgreSQL
   - Seems arbitrary
   - Better to compose in profiles

4. ⚠️ **bundle-ml-teaching depends on bundle-data-science**: Bundle of bundles
   - Adds indirection
   - Harder to understand dependencies

### Recommendation: **C** - Keep but consider deprecation

**Rationale:**
- Bundles work for simple aggregation
- BUT could be replaced by profile includes
- May cause layer bloat
- Consider moving to profile-level composition

---

## Cross-Cutting Issues

### 1. Version Management Chaos

**Three different patterns:**

```bash
# Pattern 1: Hardcoded versions
TINYTEX_VERSION="2025.05"  # texlive

# Pattern 2: Artefacts/versions.json lookup
QUARTO_VERSION=$(resolve_version "quarto")  # quarto, gh-cli, etc.

# Pattern 3: SDKMAN latest
sdk install java  # java-jdk
```

**Problem:** No consistency, hard to audit versions

**Solution:** Standardize on Artefacts/versions.json for ALL external downloads

---

### 2. Duplicate Architecture Detection

**Found in 10+ features:**
```bash
# prompt-helpers
ARCH=$(arch_map "${TARGETPLATFORM:-$(uname -m)}")

# quarto
ARCH=$(case "$(uname -m)" in x86_64) echo "amd64" ;; ...)

# kubernetes-tools
ARCH=$(arch_map "${TARGETPLATFORM:-$(uname -m)}")
```

**Problem:** Same logic copy-pasted everywhere

**Solution:** Use shared `arch.sh` consistently (already exists!)

---

### 3. Duplicate Checksum Resolution

**Found in prompt-helpers, quarto, others:**
```bash
resolve_checksum() {
  local tool="$1" ver="$2" arch="$3" cs=""
  if [ -f "${PWD}/Artefacts/features/${tool}/checksums.json" ]; then
    cs=$(jq -r ...)
  ...
}
```

**Problem:** 50+ line function duplicated in 8+ features

**Solution:** Extract to shared helper function

---

### 4. Duplicate Toolcache Logic

**Found in prompt-helpers, quarto, gh-cli, kubernetes-tools, tilt:**

```bash
if command -v toolcache-get >/dev/null 2>&1; then
  PREFIX=$(toolcache-get "tool" "$VERSION" ...)
  ...
fi
```

**Problem:** Complex logic (30-50 lines) duplicated 5+ times

**Solution:** Create shared binary installer helper:
```bash
install_binary_tool() {
  local tool="$1"
  local dest="$2"
  # Handle: version, arch, checksum, toolcache, download, extract
}
```

---

## Priority Recommendations

### 🔴 URGENT (Do First)

1. **Split quarto feature** (335 lines → ~80 lines per piece)
   - Biggest offender
   - Blocks all quarto profiles
   - Clear win for caching

2. **Fix database Python dependencies**
   - postgresql-client, mysql-client
   - Creating hidden circular dependencies
   - Can break builds

3. **Extract shared binary installer**
   - Used by: gh-cli, tilt, kubernetes-tools, quarto, prompt-helpers
   - 40% code reduction in these features

### 🟡 HIGH PRIORITY (Do Next)

4. **Split kubernetes-tools** (149 lines → 5 focused features)
   - kubectl, helm, k9s should be independent
   - Better caching per tool

5. **Refactor python-conda** (225 lines → ~80 lines per piece)
   - Split base install from config
   - Better caching

6. **Simplify jupyter-kernels** (105 lines → ~40 lines each)
   - One feature per kernel
   - Clearer failure modes

### 🟢 MEDIUM PRIORITY (Do Soon)

7. **Split dev-tools** (build vs monitoring)
8. **Rename lsp-tools** → pyright
9. **Document/fix codeserver-extensions** (doesn't actually install)
10. **Standardize version management** (all use Artefacts)

### ⚪ LOW PRIORITY (Nice to Have)

11. **Rename docker-cli-helper** → docker-group-helper
12. **Review bundle features** (consider profile-level composition)
13. **Extract arch detection** to single shared function
14. **Extract checksum resolution** to shared helper

---

## Patterns Identified

### ✅ GOOD Patterns (Replicate These)

1. **Simple focused features**: redis-client (8 lines), typescript (7 lines)
2. **Clear dependency chains**: node → lsp-tools
3. **Version from Artefacts**: Used by ~50% of features
4. **User permission helpers**: `fh_ensure_user_dirs` usage

### ❌ BAD Patterns (Avoid These)

1. **Monolithic multi-tool features**: quarto (335), prompt-helpers (228), kubernetes-tools (149)
2. **Hidden dependencies**: Database features using pip without declaring python-base dependency
3. **Duplicate complex logic**: Version/arch/checksum resolution copy-pasted
4. **Meta-features with duplicate logic**: java-devtools duplicates java-jdk

### 📋 Pattern to Extract: Binary Installer

**Create shared helper:**
```bash
# feature_helpers.sh addition
install_versioned_binary() {
  local tool="$1"
  local binary_name="${2:-$tool}"
  local install_dir="${3:-/usr/local/bin}"

  # Resolve version from Artefacts
  # Detect architecture
  # Resolve checksum
  # Try toolcache-get
  # Download if needed
  # Verify checksum
  # Extract and install
  # Set permissions
}
```

**Used by:** gh-cli, tilt, kubectl, helm, k9s, gitstatus, quarto-binary

---

## Summary Statistics

| Category | Features | Avg Lines | Issues Found | Priority |
|----------|----------|-----------|--------------|----------|
| Python | 5 | 88 | 5 | 🟡 High |
| Database | 4 | 60 | 4 | 🔴 Urgent |
| Node/Web | 4 | 20 | 3 | 🟢 Medium |
| Containers | 4 | 81 | 5 | 🟡 High |
| Editor/IDE | 3 | 67 | 3 | 🟢 Medium |
| Shell/Env | 4 | 105 | 4 | 🟡 High |
| Build/Dev | 4 | 62 | 3 | 🟢 Medium |
| Docs | 3 | 179 | 5 | 🔴 Urgent |
| Java | 8 | 84 | 4 | (Analyzed) |
| Bundles | 12 | 5 | 4 | ⚪ Low |

**Total Features:** 46 (excluding _lib)
**Features with issues:** 40 (87%)
**Monolithic features (>150 lines):** 5
**Redundant logic instances:** 20+

---

## Conclusion

The feature architecture has **significant technical debt** similar to but **worse than** the Java feature issues. The key problems are:

1. **Monolithic features** doing too much (quarto, prompt-helpers, kubernetes-tools)
2. **Hidden dependencies** causing potential build failures (database → python)
3. **Massive code duplication** in binary installation logic
4. **Inconsistent version management** across features
5. **Unclear responsibilities** (lsp-tools, docker-cli-helper)

**Recommended Action Plan:**
1. Start with quarto (biggest offender)
2. Fix database Python dependencies (breaks builds)
3. Extract shared binary installer (40% code reduction)
4. Refactor monolithic features (kubernetes-tools, python-conda)
5. Standardize patterns across remaining features

**Expected Benefits:**
- 30-40% reduction in feature code
- Better Docker layer caching (fewer invalidations)
- Clearer dependency chains
- Easier maintenance and testing
- Faster builds (parallel feature installs)
