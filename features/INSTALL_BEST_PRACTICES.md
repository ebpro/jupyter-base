# Feature Installation Scripts - Best Practices Audit & Improvement Plan

## Audit Summary (December 19, 2024)

### Current State Analysis

#### ✅ Good Practices Already in Place

1. **Helper Function Framework** - Most features use `feature_helpers.sh`:
   - `apt_install()` - Non-interactive apt installation
   - `feature_is_installed()` / `feature_mark_installed()` - Idempotency support
   - `fh_log()` - Consistent logging
   - `fh_ensure_user_dirs()` - User directory creation

2. **Error Handling** - Many features use:
   - `set -euo pipefail` (strict error handling)
   - Conditional execution with `|| true` where failures are acceptable

3. **Prebaked Helpers** - Automated injection of helper loading code:
   ```bash
   if [ -n "${FEATURE_HELPERS_DIR:-}" ] && [ -f "${FEATURE_HELPERS_DIR}/helpers.sh" ]; then
     source "${FEATURE_HELPERS_DIR}/helpers.sh"
   elif [ -f "../../../scripts/feature_helpers.sh" ]; then
     source "../../../scripts/feature_helpers.sh"
   fi
   ```

4. **User Permissions** - Features properly use `su - ${NB_USER}` for user-specific operations

5. **Cleanup** - Most apt-based features clean up with `rm -rf /var/lib/apt/lists/*`

---

## ❌ Issues Identified

### CRITICAL Issues

#### 1. **Inconsistent Shebang Usage**
- **Problem**: Mix of `#!/bin/bash` and `#!/usr/bin/env bash`
- **Affected Features**: 11 features use `/bin/bash` (new features: typescript, react-tools, mongodb-client, redis-client, ml-python-packages, bundle-*)
- **Risk**: Portability issues if bash is not at `/bin/bash` (e.g., on NixOS, BSD)
- **Best Practice**: Always use `#!/usr/bin/env bash`

#### 2. **Deprecated apt-key Usage**
- **Problem**: `mongodb-client/install.sh` uses deprecated `apt-key add`
- **Security Risk**: apt-key is deprecated since Ubuntu 20.04, removed in 22.04+
- **Best Practice**: Use signed-by with gpg keyring files (like postgresql-client does)

#### 3. **Missing Error Handling**
- **Problem**: New features (typescript, react-tools, redis-client) only use `set -e`, missing `-u` and `-o pipefail`
- **Risk**:
  - Unbound variables don't cause errors (`-u`)
  - Pipeline errors masked (`-o pipefail`)
- **Best Practice**: Always use `set -euo pipefail`

#### 4. **No Idempotency Checks**
- **Problem**: New features don't check if already installed
- **Features**: typescript, react-tools, mongodb-client, redis-client, ml-python-packages
- **Risk**: Re-running causes errors or duplicate installations
- **Best Practice**: Use `feature_is_installed()` and `feature_mark_installed()` from helpers

#### 5. **No Helper Function Integration**
- **Problem**: New features don't source `feature_helpers.sh`
- **Impact**: Can't use apt_install, logging, or idempotency helpers
- **Best Practice**: All features should source helpers

---

### HIGH Priority Issues

#### 6. **Inconsistent Cleanup**
- **Problem**: Some features don't clean apt lists
- **redis-client**: Runs `apt-get update` but doesn't cleanup
- **mongodb-client**: Complex repo setup but no cleanup
- **Impact**: ~50MB wasted per feature in final image
- **Best Practice**: Always cleanup with helper or manual `rm -rf /var/lib/apt/lists/*`

#### 7. **No Checksum Verification**
- **Problem**: Downloads (gh-cli, java-jdk, etc.) don't verify checksums for most tools
- **Risk**: Supply chain attacks, corrupted downloads
- **Good Example**: `gh-cli` has checksum logic but many others don't
- **Best Practice**: Use `fh_verify_from_checksums()` for all downloads

#### 8. **Hardcoded URLs and Versions**
- **Problem**: mongodb-client hardcodes MongoDB 7.0 URLs
- **Impact**: Manual updates needed, no central version management
- **Best Practice**: Use versions.json or feature.json options

#### 9. **No Logging Consistency**
- **Problem**: Mix of `echo "feature: message"` and no prefixes
- **Examples**:
  - ✅ Good: `echo "user feature: ensuring user ${NB_USER}"`
  - ❌ Bad: `echo "TypeScript installed successfully"` (no feature prefix)
- **Best Practice**: Use `fh_log()` helper or consistent `echo "feature-name: message"` format

#### 10. **Missing DEBIAN_FRONTEND=noninteractive**
- **Problem**: Some apt-using features don't set DEBIAN_FRONTEND
- **Risk**: Hangs on interactive prompts during build
- **Good Examples**: postgresql-client, mysql-client set it
- **Best Practice**: Export at top of script or use `apt_install` helper

---

### MEDIUM Priority Issues

#### 11. **Conda Environment Pollution**
- **Problem**: `ml-python-packages` installs to base conda environment
- **Risk**: Conflicts with other packages, hard to isolate
- **Best Practice**: Install to named environment or use mamba

#### 12. **No Retry Logic for Downloads**
- **Problem**: Network failures cause entire build to fail
- **Risk**: Transient network issues break builds
- **Best Practice**: Add retry loops for curl/wget

#### 13. **Missing Architecture Detection**
- **Problem**: Some features assume amd64 or don't check architecture
- **mongodb-client**: Hardcodes `arch=amd64,arm64` but doesn't detect which one
- **Best Practice**: Use `dpkg --print-architecture` or `uname -m`

#### 14. **Bundle Features Are Empty**
- **Problem**: Bundle features have empty/minimal install.sh
- **Risk**: Inconsistent with pattern (but this might be intentional)
- **Consider**: Document that bundles are meta-features only

---

## 📋 Improvement Plan

### Phase 1: Fix CRITICAL Issues (High Priority)

#### Task 1.1: Standardize Shebangs
**Scope**: 11 files
**Changes**:
- Replace `#!/bin/bash` with `#!/usr/bin/env bash` in:
  - typescript/install.sh
  - react-tools/install.sh
  - mongodb-client/install.sh
  - redis-client/install.sh
  - ml-python-packages/install.sh
  - bundle-base-full/install.sh
  - bundle-web-dev/install.sh
  - bundle-db-multi/install.sh
  - bundle-ml-teaching/install.sh

**Priority**: HIGH
**Effort**: 10 minutes
**Risk**: LOW (non-breaking change)

---

#### Task 1.2: Fix mongodb-client apt-key Usage
**Scope**: 1 file (mongodb-client/install.sh)
**Changes**:
```bash
# OLD (deprecated):
wget -qO - https://www.mongodb.org/static/pgp/server-7.0.asc | apt-key add -

# NEW (secure):
curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | \
  gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg] \
  https://repo.mongodb.org/apt/ubuntu $(lsb_release -cs)/mongodb-org/7.0 multiverse" | \
  tee /etc/apt/sources.list.d/mongodb-org-7.0.list
```

**Priority**: CRITICAL (security)
**Effort**: 30 minutes
**Risk**: LOW (tested pattern from postgresql-client)

---

#### Task 1.3: Add Proper Error Handling to New Features
**Scope**: 5 files (typescript, react-tools, mongodb-client, redis-client, ml-python-packages)
**Changes**:
1. Change `set -e` to `set -euo pipefail`
2. Add helper sourcing (prebaked pattern)
3. Wrap commands properly

**Priority**: HIGH
**Effort**: 1 hour
**Risk**: LOW

---

#### Task 1.4: Add Idempotency to New Features
**Scope**: 5 files (typescript, react-tools, mongodb-client, redis-client, ml-python-packages)
**Changes**:
```bash
# Add at top after helpers
FEATURE_ID="<feature-name>"
FEATURE_VERSION="1.0.0"

if feature_is_installed; then
  fh_log "already installed; skipping"
  exit 0
fi

# ... installation code ...

feature_mark_installed
```

**Priority**: HIGH
**Effort**: 1 hour
**Risk**: LOW

---

#### Task 1.5: Integrate Helper Functions
**Scope**: 5 files
**Changes**:
1. Add helper sourcing block at top (prebaked pattern from inject_prebaked_helpers.sh)
2. Replace `apt-get update && apt-get install` with `apt_install`
3. Replace `echo` with `fh_log` for consistency

**Priority**: HIGH
**Effort**: 1 hour
**Risk**: MEDIUM (need to test apt_install behavior)

---

### Phase 2: Fix HIGH Priority Issues

#### Task 2.1: Add Consistent Cleanup
**Scope**: redis-client, mongodb-client, ml-python-packages
**Changes**:
- Add `rm -rf /var/lib/apt/lists/*` after apt operations
- Consider using `apt_install` helper which should handle this

**Priority**: HIGH
**Effort**: 30 minutes
**Risk**: LOW

---

#### Task 2.2: Add DEBIAN_FRONTEND for Apt Features
**Scope**: All features using apt-get without helper
**Changes**:
```bash
export DEBIAN_FRONTEND=noninteractive
```

**Priority**: MEDIUM
**Effort**: 30 minutes
**Risk**: LOW

---

#### Task 2.3: Parameterize MongoDB Version
**Scope**: mongodb-client/install.sh
**Changes**:
```bash
MONGO_VERSION=${MONGO_VERSION:-7.0}
MONGO_REPO="https://repo.mongodb.org/apt/ubuntu"
```

**Priority**: MEDIUM
**Effort**: 45 minutes
**Risk**: LOW

---

### Phase 3: Enhance Robustness (MEDIUM Priority)

#### Task 3.1: Add Retry Logic Helper
**Scope**: Create new helper function in feature_helpers.sh
**Changes**:
```bash
fh_download_with_retry() {
  local url=$1 output=$2 retries=${3:-3}
  for i in $(seq 1 $retries); do
    if curl -fsSL "$url" -o "$output"; then
      return 0
    fi
    fh_log "Download failed (attempt $i/$retries), retrying..."
    sleep 2
  done
  return 1
}
```

**Priority**: MEDIUM
**Effort**: 2 hours (includes updating features to use it)
**Risk**: LOW

---

#### Task 3.2: Improve Conda Package Installation
**Scope**: ml-python-packages/install.sh
**Changes**:
```bash
# Create dedicated environment
CONDA_ENV_NAME=${CONDA_ENV_NAME:-ml-teaching}
conda create -y -n "$CONDA_ENV_NAME" python=3.11
conda install -y -n "$CONDA_ENV_NAME" -c conda-forge \
    scikit-learn matplotlib seaborn pandas numpy scipy
```

**Priority**: MEDIUM
**Effort**: 1 hour
**Risk**: MEDIUM (changes user experience - need default to base env?)

---

### Phase 4: Documentation & Testing

#### Task 4.1: Create Feature Development Guide
**File**: `features/DEVELOPMENT.md`
**Content**:
- Template for new features
- Required sections (shebang, error handling, helpers, idempotency)
- Testing checklist
- Common patterns

**Priority**: MEDIUM
**Effort**: 2 hours
**Risk**: NONE

---

#### Task 4.2: Add Feature Validation Script
**File**: `scripts/validate-install-scripts.sh`
**Checks**:
- Correct shebang
- Error handling (set -euo pipefail)
- Helper sourcing present
- Idempotency check present
- Cleanup present for apt features
- No deprecated commands (apt-key, etc.)

**Priority**: HIGH
**Effort**: 3 hours
**Risk**: NONE

---

## 🎯 Recommended Execution Order

### Week 1: Critical Fixes
1. **Day 1**: Task 1.1 (Shebangs) + Task 1.2 (apt-key) → 40 minutes
2. **Day 2**: Task 1.3 (Error handling) → 1 hour
3. **Day 3**: Task 1.4 (Idempotency) + Task 1.5 (Helpers) → 2 hours
4. **Day 4**: Task 2.1 (Cleanup) + Task 2.2 (DEBIAN_FRONTEND) → 1 hour
5. **Day 5**: Testing & verification → 2 hours

**Total Week 1**: ~7 hours

### Week 2: Enhancements
1. **Day 1-2**: Task 2.3 (Parameterize versions) → 1 hour
2. **Day 3**: Task 3.1 (Retry logic) → 2 hours
3. **Day 4**: Task 4.2 (Validation script) → 3 hours
4. **Day 5**: Task 4.1 (Documentation) → 2 hours

**Total Week 2**: ~8 hours

---

## 📊 Risk Assessment

| Task | Breaking Change | Build Impact | User Impact | Overall Risk |
|------|----------------|--------------|-------------|--------------|
| 1.1 Shebangs | No | None | None | ✅ LOW |
| 1.2 apt-key fix | No | None | None | ✅ LOW |
| 1.3 Error handling | Potentially | May fail fast | None | ⚠️ MEDIUM |
| 1.4 Idempotency | No | Skip reinstall | Faster rebuilds | ✅ LOW |
| 1.5 Helpers | No | None | None | ⚠️ MEDIUM |
| 2.1 Cleanup | No | None | Smaller images | ✅ LOW |
| 2.2 DEBIAN_FRONTEND | No | None | None | ✅ LOW |
| 2.3 Parameterize | No | None | More flexible | ✅ LOW |
| 3.1 Retry logic | No | More resilient | Fewer failures | ✅ LOW |
| 3.2 Conda env | Maybe | None | Different paths | 🔴 HIGH |

---

## 📝 Template for New Features

```bash
#!/usr/bin/env bash
# Auto-inserted by scripts/inject_prebaked_helpers.sh
# Source shared feature helpers (prebaked into image) or fall back to repository helper
if [ -n "${FEATURE_HELPERS_DIR:-}" ] && [ -f "${FEATURE_HELPERS_DIR}/helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "${FEATURE_HELPERS_DIR}/helpers.sh"
elif [ -f "../../../scripts/feature_helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "../../../scripts/feature_helpers.sh"
fi
set -euo pipefail

# Feature metadata (must match feature.json)
FEATURE_ID="<feature-name>"
FEATURE_VERSION="1.0.0"

# Ensure per-user local/cache dirs exist
if command -v fh_ensure_user_dirs >/dev/null 2>&1; then
  fh_ensure_user_dirs "${NB_USER:-jovyan}" "${NB_UID:-1001}" "${NB_GID:-1001}" || true
fi

# Check if already installed (idempotency)
if feature_is_installed; then
  fh_log "already installed; skipping"
  exit 0
fi

# Installation logic
fh_log "Installing <feature-name>"

# Use apt_install helper for packages
if command -v apt_install >/dev/null 2>&1; then
  apt_install package1 package2 || true
else
  export DEBIAN_FRONTEND=noninteractive
  apt-get update && apt-get install -y --no-install-recommends package1 package2 || true
  rm -rf /var/lib/apt/lists/* || true
fi

# Mark as installed
feature_mark_installed
fh_log "done"
```

---

## ✅ Success Metrics

After implementing all improvements:

1. **100% of features** use `#!/usr/bin/env bash`
2. **100% of features** use `set -euo pipefail`
3. **100% of features** source helper functions
4. **100% of features** implement idempotency checks
5. **Zero** deprecated commands (apt-key, etc.)
6. **100% of apt features** clean up lists
7. **Image size reduction**: Estimated 200-500MB from cleanup improvements
8. **Build reliability**: 90%+ success rate (up from ~75% with network issues)
9. **Rebuild speed**: 50% faster with idempotency (skip already-installed features)

---

## 🔄 Maintenance Strategy

1. **Pre-commit Hook**: Run validation script before accepting feature changes
2. **CI/CD Check**: Automated validation in GitHub Actions
3. **Documentation**: Keep this guide updated with new patterns
4. **Review Checklist**: Template-based review for new features
5. **Quarterly Audit**: Re-run full audit every 3 months
