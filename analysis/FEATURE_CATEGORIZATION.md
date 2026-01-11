# Feature Categorization Guide

## How to Categorize Features for Layer Strategy

### The Three Categories

#### 1. **DIRECTORY_ISOLATED** ✅ Can be built in parallel layers
Features that install to a single, dedicated directory that can be COPY'd between Docker stages.

**Detection patterns:**
- Installs to dedicated directory: `~/.sdkman`, `/opt/node`, `/opt/texlive`, `/usr/local/go`
- Downloads and extracts to specific location
- Doesn't modify shared system locations
- No pip/conda/apt package installation

**Examples from your codebase:**
- `java-sdkman` → `~/.sdkman/` (can COPY entire dir)
- `node` → `/opt/node/` (can COPY entire dir)
- `texlive` → `/opt/texlive/` (can COPY entire dir)
- `gh-cli` → Downloads binary to `/usr/local/bin/gh` (can COPY)
- `graalvm` → Installs via SDKMAN to isolated dir
- `quarto-cli` → Downloads to `/opt/quarto/`
- `jetbrains-gateway` → Installs to isolated directory
- `git-lfs` → Binary download to `/usr/local/bin/`

#### 2. **SYSTEM_SHARED** ⚠️ Must be sequential within domain
Features that modify shared system directories that multiple features access.

**Detection patterns:**
- `pip install` → Modifies `/opt/conda/lib/python3.12/site-packages/`
- `conda install` → Modifies conda environment
- `apt-get install` → Modifies `/usr/lib/`, `/usr/bin/`, etc.
- Modifies Python site-packages
- Adds system libraries that other features depend on

**Examples from your codebase:**
- `python-conda` → Base Python environment (must be FIRST in Python stack)
- `pip-requirements` → Adds packages to conda environment (depends on python-conda)
- `jupyter-base` → Adds Jupyter to conda environment (depends on pip-requirements)
- `jupyter-kernels` → More packages to conda environment (depends on jupyter-base)
- `ml-python-packages` → conda install packages (depends on python-conda)
- `quarto-python` → pip install Python packages
- `base-apt` → apt packages (system libraries)
- `dev-tools` → apt packages (development tools)
- `mysql-client` → apt packages (database libraries)
- `mongodb-client` → apt packages (database tools)
- `postgresql-client` → apt packages (database client)

#### 3. **CONFIG_FILE** ⚠️ Requires merge strategy
Features that modify shared configuration files.

**Detection patterns:**
- Modifies `.bashrc`, `.zshrc`, `.profile`
- Modifies conda configs
- Modifies system-wide configs in `/etc/`
- Appends to PATH or environment variables

**Examples from your codebase:**
- `zsh-config` → Modifies shell configs
- `prompt-helpers` → Modifies shell prompts
- `user` → Sets up user environment
- `startup` → Modifies startup scripts
- `code-server` → Modifies VS Code configs
- `codeserver-extensions` → Installs extensions (config state)

---

## Practical Detection Method

### Step 1: Examine the install.sh script

```bash
# Look for installation patterns
grep -E "apt-get install|pip install|conda install|wget|tar -xz|git clone|COPY" \
  .devcontainer/features/*/install.sh
```

### Step 2: Check what directories are modified

```bash
# For a specific feature, check where it installs
cat .devcontainer/features/java-sdkman/install.sh | grep -E "SDKMAN_DIR|HOME|/opt"
```

### Step 3: Apply decision tree

```
Does it use pip/conda/apt?
├─ YES → SYSTEM_SHARED (must be sequential within domain)
└─ NO → Does it install to a single directory?
    ├─ YES → DIRECTORY_ISOLATED (can be parallel)
    └─ NO → Does it modify config files?
        ├─ YES → CONFIG_FILE (needs merge strategy)
        └─ NO → DIRECTORY_ISOLATED (likely a binary download)
```

---

## Your 40 Features Categorized

### DIRECTORY_ISOLATED (can build in parallel) - 15 features

1. `java-sdkman` - Installs to `~/.sdkman/`
2. `java-jdk` - Uses SDKMAN, isolated
3. `java-gradle` - Uses SDKMAN, isolated
4. `java-maven` - Uses SDKMAN, isolated
5. `java-devtools` - Uses SDKMAN, isolated
6. `graalvm` - Uses SDKMAN, isolated
7. `kotlin` - Uses SDKMAN, isolated
8. `node` - Installs to `/opt/node/`
9. `texlive` - Installs to `/opt/texlive/`
10. `quarto-cli` - Downloads to `/opt/quarto/`
11. `quarto-chromium` - Downloads to dedicated dir
12. `gh-cli` - Binary to `/usr/local/bin/gh`
13. `git-lfs` - Binary download
14. `jetbrains-gateway` - Isolated installation
15. `tilt` - Binary download

### SYSTEM_SHARED (must be sequential within domain) - 20 features

**Python Domain (must be sequential: conda → pip → jupyter → kernels):**
1. `python-conda` - Base conda environment **[FIRST in Python stack]**
2. `python-base` - Python setup (depends on conda)
3. `pip-requirements` - Adds to conda site-packages
4. `jupyter-base` - Adds Jupyter to conda
5. `jupyter-kernels` - More conda packages
6. `ml-python-packages` - conda install packages
7. `quarto-python` - pip install packages
8. `python-lsp` - Language server packages
9. `react-tools` - npm packages (if installed via pip)
10. `typescript` - npm packages (if installed via pip)

**System/APT Domain (sequential within this domain):**
11. `base-apt` - System libraries **[FIRST in APT stack]**
12. `dev-tools` - Development apt packages
13. `mysql-client` - Database apt packages
14. `mysql-client-cli` - CLI tool (pip)
15. `mongodb-client` - Database apt packages
16. `postgresql-client` - Database apt packages
17. `postgresql-client-cli` - CLI tool (pip)
18. `redis-client` - Database apt packages
19. `kubernetes-client` - kubectl (system binary)
20. `kubernetes-tools` - k8s apt packages

**Container Domain (sequential):**
21. `docker-cli-helper` - Docker setup
22. `docker-dind` - Docker-in-Docker
23. `podman` - Alternative container runtime

### CONFIG_FILE (needs merge strategy) - 5 features

1. `user` - User setup, environment
2. `zsh-config` - Shell configuration
3. `prompt-helpers` - Shell prompt modifications
4. `startup` - Startup scripts
5. `code-server` - VS Code configuration
6. `codeserver-extensions` - VS Code extensions

---

## Implementation: Adding Categories to Analyzer

You can enhance your analyzer to automatically categorize:

```python
def categorize_feature_type(self, feature_name: str) -> str:
    """Categorize feature by installation type."""

    # Define patterns
    isolated_patterns = {
        'java-sdkman', 'java-jdk', 'java-gradle', 'java-maven',
        'java-devtools', 'graalvm', 'kotlin', 'node', 'texlive',
        'quarto-cli', 'quarto-chromium', 'gh-cli', 'git-lfs',
        'jetbrains-gateway', 'tilt'
    }

    python_packages = {
        'python-conda', 'python-base', 'pip-requirements',
        'jupyter-base', 'jupyter-kernels', 'ml-python-packages',
        'quarto-python', 'python-lsp'
    }

    apt_packages = {
        'base-apt', 'dev-tools', 'mysql-client', 'mongodb-client',
        'postgresql-client', 'redis-client', 'kubernetes-client'
    }

    config_features = {
        'user', 'zsh-config', 'prompt-helpers', 'startup',
        'code-server', 'codeserver-extensions'
    }

    if feature_name in isolated_patterns:
        return 'DIRECTORY_ISOLATED'
    elif feature_name in python_packages or feature_name in apt_packages:
        return 'SYSTEM_SHARED'
    elif feature_name in config_features:
        return 'CONFIG_FILE'
    else:
        # Default: check install script
        return self._detect_from_script(feature_name)
```

---

## Next Steps

1. **Validate this categorization** by examining specific features you're unsure about
2. **Update your analyzer** to include feature types in output
3. **Create layer-strategy.yml** with explicit sequential dependencies
4. **Test with one profile** to verify the categorization is correct

**Question:** Would you like me to:
- A) Update the analyzer script to include these categories automatically?
- B) Create a layer-strategy.yml config file based on this categorization?
- C) Examine specific features you're unsure about?
