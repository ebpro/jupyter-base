# Feature Testing Framework

**Status**: ✅ **IMPLEMENTED**  
**Date**: December 19, 2025  
**Purpose**: Automated testing and validation of devcontainer features

---

## Overview

This testing framework provides comprehensive validation of features at multiple levels:

1. **Individual Feature Testing** - Test single features in isolation
2. **PostInstall Check Validation** - Run all postInstallCheck commands
3. **Batch Feature Testing** - Test multiple features with reporting
4. **Dependency Validation** - Verify feature dependency graphs
5. **Profile Testing** - Smoke test complete profile images

---

## Testing Tools

### 1. test-feature.sh - Individual Feature Tester

Tests a single feature by building a minimal container with just that feature and its dependencies.

**Usage:**
```bash
# Test a feature (requires pre-built test image)
./scripts/test-feature.sh node

# Build and test a feature
./scripts/test-feature.sh postgresql-client --build-first

# Verbose output showing all test details
./scripts/test-feature.sh kubernetes-client --build-first --verbose
```

**What it tests:**
- ✅ Install script exists and is executable
- ✅ postInstallCheck command passes
- ✅ All `provides` tools/binaries are available
- ✅ Feature marker file created
- ✅ User permissions are correct

**Example output:**
```
====================================================================
Feature Testing: node
====================================================================
→ Name: Node.js Runtime
→ Version: 1.0.0
→ Dependencies: user _lib/download-release
→ Provides: node npm

✓ Test image built successfully

====================================================================
Running Tests
====================================================================

✓ Install script exists
→ Test: postInstallCheck command
✓ postInstallCheck passed
→ Checking provided tools/packages...
→ Test: Tool 'node' available
✓ Tool 'node' available
→ Test: Tool 'npm' available
✓ Tool 'npm' available
✓ Feature marker exists
✓ User permissions correct

====================================================================
Test Summary
====================================================================
Feature: node
Passed: 6
Failed: 0
====================================================================
✓ All tests passed!
```

---

### 2. run-postinstall-checks.py - PostInstall Check Runner

Executes all `postInstallCheck` commands defined in feature.json files against a running container image.

**Usage:**
```bash
# Check all features in an image
./scripts/run-postinstall-checks.py ghcr.io/ebpro/jupyter-base:dev

# Check specific features only
./scripts/run-postinstall-checks.py jupyter:local --features node,python-base,gh-cli

# Verbose output with command details
./scripts/run-postinstall-checks.py jupyter:test --verbose

# Detect installed features
./scripts/run-postinstall-checks.py jupyter:test --detect

# Run as different user
./scripts/run-postinstall-checks.py jupyter:test --user root
```

**What it does:**
- 📋 Loads all feature.json files from `.devcontainer/features/`
- 🔍 Extracts postInstallCheck commands
- 🐳 Runs commands in target container image
- ✅ Reports pass/fail status
- 📊 Generates summary statistics

**Example output:**
```
======================================================================
PostInstallCheck Runner
======================================================================
→ Image: ghcr.io/ebpro/jupyter-base:dev
→ User: jovyan

→ Loading feature definitions...
→ Found 45 features with postInstallCheck

======================================================================
Running PostInstall Checks
======================================================================

→ Testing: node
✓ node: Verify node and npm are available

→ Testing: python-conda
✓ python-conda: Verify conda is installed

→ Testing: gh-cli
✓ gh-cli: Verify gh CLI is installed

...

======================================================================
Summary
======================================================================
Total features: 45
Passed: 42
Failed: 2
Skipped: 1
======================================================================
✗ 2 checks failed
```

---

### 3. test-all-features.sh - Batch Feature Tester

Orchestrates testing of multiple features with parallel execution support and JSON reporting.

**Usage:**
```bash
# Test all features (requires pre-built test images)
./scripts/test-all-features.sh

# Build and test all features sequentially
./scripts/test-all-features.sh --build

# Test specific features in parallel
./scripts/test-all-features.sh --features node,python-base,gh-cli --parallel --build

# Generate JSON report
./scripts/test-all-features.sh --build --report test-results.json

# Parallel with max 8 jobs
./scripts/test-all-features.sh --parallel --jobs 8 --build
```

**Features:**
- 🔄 Sequential or parallel execution
- 📊 JSON report generation
- 🎯 Feature filtering
- 🔧 Automatic image building
- 📝 Detailed logging

**Example output:**
```
====================================================================
Feature Testing Suite
====================================================================
→ Features directory: .devcontainer/features
→ Build images: true
→ Parallel mode: true
→ Max parallel jobs: 4

→ Found 68 features to test

====================================================================
Running Tests
====================================================================

→ Running tests in parallel (max 4 jobs)...

====================================================================
Detailed Results
====================================================================
✓ node
✓ python-base
✓ gh-cli
✓ kubernetes-client
✗ some-broken-feature
⚠ _lib/checksum-verify (skipped)
...

====================================================================
Summary
====================================================================
Total features: 68
Passed: 62
Failed: 3
Skipped: 3
====================================================================
```

**JSON Report Format:**
```json
{
  "timestamp": "2025-12-19T10:30:00Z",
  "total": 68,
  "passed": 62,
  "failed": 3,
  "skipped": 3,
  "results": {
    "node": "PASS",
    "python-base": "PASS",
    "some-broken-feature": "FAIL",
    "_lib/checksum-verify": "SKIP"
  }
}
```

---

### 4. validate-feature-deps.py - Dependency Validator

Validates feature dependency graphs for correctness (already existed, enhanced docs).

**Usage:**
```bash
# Validate all features
./scripts/validate-feature-deps.py

# Validate specific profile
./scripts/validate-feature-deps.py --profile profiles/10-00-dev

# Generate sorted dependency order
./scripts/validate-feature-deps.py --sort
```

**What it checks:**
- ✅ All dependencies exist
- ✅ No circular dependencies
- ✅ No conflicts in dependency chains
- ✅ Proper topological ordering
- ✅ Profile dependency ordering

---

### 5. test-profile.sh - Profile Smoke Tester

Tests complete built profile images with feature-specific checks (already existed).

**Usage:**
```bash
# Test a built profile image
./scripts/test-profile.sh ghcr.io/ebpro/jupyter-base:dev 10-00-dev
```

---

## Testing Workflow

### Development Workflow

```bash
# 1. Create/modify a feature
vim .devcontainer/features/my-feature/install.sh
vim .devcontainer/features/my-feature/feature.json

# 2. Add postInstallCheck to feature.json
{
  "id": "my-feature",
  "postInstallCheck": {
    "command": "my-tool --version",
    "description": "Verify my-tool is installed"
  }
}

# 3. Validate dependencies
./scripts/validate-feature-deps.py

# 4. Test the feature
./scripts/test-feature.sh my-feature --build-first --verbose

# 5. Regenerate Dockerfile and test profile
./scripts/generate-dockerfile.sh --profile 10-00-dev
docker buildx build -f Dockerfile.generated --target final-10-00-dev -t test:dev .

# 6. Run postInstallCheck on built image
./scripts/run-postinstall-checks.py test:dev --features my-feature --verbose
```

### CI/CD Workflow

```bash
# 1. Validate all features
./scripts/validate-feature-deps.py || exit 1

# 2. Test critical features
./scripts/test-all-features.sh \
  --features node,python-base,gh-cli,kubernetes-client \
  --build \
  --parallel \
  --jobs 4 \
  --report feature-tests.json

# 3. Build profile images
./scripts/generate-dockerfile.sh --all-profiles
docker buildx bake -f docker-bake.generated.hcl

# 4. Run postInstallCheck on built images
for profile in dev data-science quarto-lecture; do
  ./scripts/run-postinstall-checks.py \
    "ghcr.io/ebpro/jupyter-base:${profile}" \
    --report "postinstall-${profile}.json"
done

# 5. Smoke test profiles
./scripts/test-profile.sh ghcr.io/ebpro/jupyter-base:dev 10-00-dev
```

---

## CI Integration

### GitHub Actions Example

```yaml
name: Feature Tests

on:
  pull_request:
    paths:
      - '.devcontainer/features/**'
      - 'scripts/**'
  push:
    branches: [main, develop]

jobs:
  validate-dependencies:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Validate feature dependencies
        run: ./scripts/validate-feature-deps.py
  
  test-features:
    runs-on: ubuntu-latest
    needs: validate-dependencies
    strategy:
      matrix:
        feature:
          - node
          - python-base
          - gh-cli
          - kubernetes-client
          - postgresql-client
      fail-fast: false
    
    steps:
      - uses: actions/checkout@v4
      
      - name: Setup Docker Buildx
        uses: docker/setup-buildx-action@v3
      
      - name: Test feature: ${{ matrix.feature }}
        run: |
          ./scripts/test-feature.sh ${{ matrix.feature }} \
            --build-first \
            --verbose
  
  test-profile-images:
    runs-on: ubuntu-latest
    needs: test-features
    steps:
      - uses: actions/checkout@v4
      
      - name: Setup Docker Buildx
        uses: docker/setup-buildx-action@v3
      
      - name: Build profile image
        run: |
          ./scripts/generate-dockerfile.sh --profile 10-00-dev
          docker buildx build \
            -f Dockerfile.generated \
            --target final-10-00-dev \
            -t test:dev \
            --load \
            .
      
      - name: Run postInstallCheck tests
        run: |
          ./scripts/run-postinstall-checks.py test:dev \
            --verbose \
            --report postinstall-results.json
      
      - name: Upload test results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: test-results
          path: postinstall-results.json
```

---

## Best Practices

### Writing Good PostInstallChecks

**✅ Good Examples:**

```json
{
  "postInstallCheck": {
    "command": "node --version && npm --version",
    "description": "Verify Node.js and npm are installed"
  }
}
```

```json
{
  "postInstallCheck": {
    "command": "kubectl version --client && helm version",
    "description": "Verify Kubernetes tools are installed"
  }
}
```

```json
{
  "postInstallCheck": {
    "command": "python3 -c 'import pandas; print(pandas.__version__)'",
    "description": "Verify pandas is installed in conda environment"
  }
}
```

**❌ Bad Examples:**

```json
{
  "postInstallCheck": {
    "command": "which node",  // ❌ Too minimal, doesn't verify it works
    "description": "Check node"
  }
}
```

```json
{
  "postInstallCheck": {
    "command": "curl http://external-service.com",  // ❌ Requires network
    "description": "Test network access"
  }
}
```

```json
{
  "postInstallCheck": {
    "command": "sleep 60 && docheck",  // ❌ Takes too long (30s timeout)
    "description": "Slow check"
  }
}
```

### PostInstallCheck Guidelines

1. **Keep it fast** - Commands timeout after 30 seconds
2. **No network required** - Tests should work offline
3. **Idempotent** - Can be run multiple times safely
4. **Verify functionality** - Not just existence (run `--version` or similar)
5. **Use login shell** - Commands run with `bash -lc` to load environment
6. **Exit codes matter** - Return 0 for success, non-zero for failure

---

## Troubleshooting

### Test Image Not Found

**Problem**: `./scripts/test-feature.sh node` fails with "Test image not found"

**Solution**:
```bash
# Build the test image first
./scripts/test-feature.sh node --build-first
```

### PostInstallCheck Fails But Feature Works

**Problem**: `command not found` even though feature installed correctly

**Cause**: Environment not loaded (PATH, conda, SDKMAN, etc.)

**Solution**: Commands already run with `bash -lc` (login shell). Check if feature properly sets up shell profile (~/.bashrc, ~/.zshrc).

### Parallel Tests Fail Randomly

**Problem**: Some tests pass when run alone but fail in parallel

**Cause**: Docker BuildKit cache contention with `sharing=locked`

**Solution**:
```bash
# Reduce parallel jobs
./scripts/test-all-features.sh --parallel --jobs 2

# Or run sequentially
./scripts/test-all-features.sh --build
```

### Feature Test Passes But Profile Test Fails

**Problem**: Individual feature test passes but fails in full profile

**Cause**: Feature conflicts or dependency ordering issues

**Solution**:
```bash
# Validate dependencies
./scripts/validate-feature-deps.py

# Check for conflicts in profile
./scripts/validate-feature-deps.py --profile profiles/10-00-dev

# Test with dependencies
./scripts/test-feature.sh my-feature --build-first --verbose
```

---

## Testing Metrics

### Coverage

Current feature testing coverage:

```bash
# Count features with postInstallCheck
cd .devcontainer/features
grep -r "postInstallCheck" */feature.json | wc -l

# Count total features
find . -name "feature.json" | wc -l

# Calculate coverage
```

**Expected**: 80-90% of features should have postInstallCheck

### Performance

Typical testing times (on CI with 4 CPUs):

| Test Type | Sequential | Parallel (4 jobs) |
|-----------|------------|-------------------|
| Single feature | 2-5 min | N/A |
| 10 features | 20-50 min | 8-15 min |
| All features (68) | 2-4 hours | 30-60 min |
| PostInstall checks | 5-10 min | N/A |

---

## Future Enhancements

### Planned Improvements

1. **Integration Tests**
   - Test feature interactions (e.g., Python + Jupyter + Pandas)
   - Multi-feature workflows

2. **Performance Testing**
   - Measure feature install times
   - Track image size impact
   - Identify slow features

3. **Security Scanning**
   - Vulnerability scanning of installed packages
   - License compliance checks

4. **Coverage Reporting**
   - Track which features have tests
   - Identify untested code paths

5. **Regression Testing**
   - Compare test results across versions
   - Alert on new failures

---

## Summary

### Testing Tools Created

1. ✅ [test-feature.sh](../scripts/test-feature.sh) - Individual feature tester (330 lines)
2. ✅ [run-postinstall-checks.py](../scripts/run-postinstall-checks.py) - PostInstall runner (300 lines)
3. ✅ [test-all-features.sh](../scripts/test-all-features.sh) - Batch orchestrator (280 lines)
4. ✅ Enhanced documentation for existing validators

### Quick Start

```bash
# Test a single feature
./scripts/test-feature.sh node --build-first

# Test multiple features
./scripts/test-all-features.sh --features node,python-base --build

# Validate dependencies
./scripts/validate-feature-deps.py

# Test built image
./scripts/run-postinstall-checks.py ghcr.io/ebpro/jupyter-base:dev
```

### CI Integration

Add to `.github/workflows/test-features.yml`:
```yaml
- name: Test features
  run: |
    ./scripts/validate-feature-deps.py
    ./scripts/test-all-features.sh --build --parallel --report results.json
```

---

**Total Impact**: Comprehensive testing framework covering 68 features with automated validation, parallel execution, and CI integration capabilities.
