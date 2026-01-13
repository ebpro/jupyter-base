# Feature Rename Proposal

**Goal:** Establish clear, consistent, meaningful feature names across all 70 features.

## Naming Standards

### Pattern: `<technology>[-<component>[-variant]]`

**Rules:**
1. **Singular form** (e.g., `python-tool` not `python-tools`)
2. **Explicit purpose** (avoid vague names like "base" or "tools")
3. **Consistent suffixes** within categories
4. **No abbreviations** unless industry-standard (e.g., `lsp`, `cli`, `jdk`)

---

## 🔴 HIGH PRIORITY - Confusing/Unclear Names

### Core System Features

| Current | Proposed | Reason | References |
|---------|----------|--------|------------|
| `user` | `container-user` | ❌ Too vague. What user? | bundle-base-full |
| `base-apt` | `system-essentials` | ❌ "base" is generic, "apt" is implementation detail | bundle-base-full |
| `startup` | `container-init` | ❌ Unclear what starts up | bundle-base-full, quarto-lecture-containers |
| `dev-tools` | `build-essentials` | ❌ Vague. What tools? | bundle-base-full |

**Impact:** 4 features, referenced in 3 bundles + 1 profile

**Justification:**
- `user` → `container-user`: Makes it clear this creates the non-root container user
- `base-apt` → `system-essentials`: Describes what it provides (essential system packages), not how
- `startup` → `container-init`: Clarifies it handles container initialization scripts
- `dev-tools` → `build-essentials`: Matches Ubuntu package naming convention

---

## 🟡 MEDIUM PRIORITY - Consistency Improvements

### CLI Tool Naming

| Current | Proposed | Reason | References |
|---------|----------|--------|------------|
| `gh-cli` | `github-cli` | ⚠️ Inconsistent abbreviation | bundle-base-full, bundle-cicd-teaching |
| `docker-cli` | *(keep)* | ✅ Industry standard | *(many)* |
| `quarto-cli` | *(keep)* | ✅ Clear, distinguishes from meta `quarto` | *(many)* |

**Alternative:** Drop all `-cli` suffixes since CLI is implied for tool names
- `github-cli` → `github` (simpler, still clear)
- `docker-cli` → `docker-client` (aligns with `postgresql-client`)
- `quarto-cli` → keep (needed to distinguish from `quarto` meta-feature)

**Recommendation:** Keep `-cli` for now, just standardize `gh-cli` → `github-cli`

**Impact:** 1 feature, 2 bundle references

---

### Plural vs Singular

| Current | Proposed | Reason | References |
|---------|----------|--------|------------|
| `kubernetes-tools` | `kubernetes-extras` | ⚠️ Inconsistent plural | *(check usage)* |
| `codeserver-extensions` | *(keep)* | ✅ Extensions are inherently plural | code-server |
| `jupyter-kernels` | *(keep)* | ✅ Kernels are inherently plural | bundle-data-science |
| `ml-python-packages` | `ml-python-libs` | ⚠️ Inconsistent, but "packages" is accurate | bundle-ml-teaching |
| `pip-requirements` | *(keep)* | ✅ Refers to requirements.txt concept | *(many)* |

**Impact:** 2 features

---

### Library/Helper Naming

| Current | Proposed | Reason | References |
|---------|----------|--------|------------|
| `_lib` | `_helpers` | ⚠️ More descriptive | *(internal - many)* |

**Impact:** 1 meta-feature, many bundle references (but prefixed with `_` so low visibility)

---

## 🟢 LOW PRIORITY - Nice-to-Have Improvements

### Better Descriptive Names

| Current | Proposed | Reason | References |
|---------|----------|--------|------------|
| `prompt-helpers` | `shell-prompts` | 💡 More specific | bundle-base-full |
| `jetbrains-gateway` | *(keep)* | ✅ Product name | *(specialized)* |
| `code-server` | *(keep)* | ✅ Product name | *(specialized)* |
| `graalvm` | *(keep)* | ✅ Product name | *(java profiles)* |

**Impact:** 1 feature

---

### Bundle Naming (Already Good ✅)

All bundles follow clear pattern: `bundle-<purpose>`
- `bundle-base-full` ✅
- `bundle-java-build` ✅
- `bundle-container-dev` ✅
- `bundle-quarto-full` ✅

**No changes needed.**

---

## Summary of Proposed Renames

### Confirmed Renames (5 features)

```yaml
renames:
  user: container-user
  base-apt: system-essentials
  startup: container-init
  dev-tools: build-essentials
  gh-cli: github-cli
```

### Files Requiring Updates

**Feature directories:**
- `features/user/` → `features/container-user/`
- `features/base-apt/` → `features/system-essentials/`
- `features/startup/` → `features/container-init/`
- `features/dev-tools/` → `features/build-essentials/`
- `features/gh-cli/` → `features/github-cli/`

**Bundle feature.json files (dependsOn arrays):**
- `features/bundle-base-full/feature.json` (5 references)
- `features/bundle-cicd-teaching/feature.json` (1 reference)

**Profile matrix files:**
- `profiles/matrix/quarto-lecture.yaml` (1 reference: startup)

**Generated files (will auto-update):**
- `generated/profiles/*`
- `generated/feature-matrix.md`

---

## Implementation Strategy

### Phase 1: Rename Feature Directories
```bash
mv features/user features/container-user
mv features/base-apt features/system-essentials
mv features/startup features/container-init
mv features/dev-tools features/build-essentials
mv features/gh-cli features/github-cli
```

### Phase 2: Update feature.json IDs
Update `id` field in each renamed feature's feature.json

### Phase 3: Update Bundle Dependencies
Update `dependsOn` arrays in:
- bundle-base-full
- bundle-cicd-teaching

### Phase 4: Update Profile References
Update `profiles/matrix/quarto-lecture.yaml`

### Phase 5: Regenerate & Validate
```bash
./scripts/features/generate-feature-readmes.py --force
./scripts/validate/validate-feature-structure.py
./scripts/generate-profiles-matrix.py # regenerate all profiles
```

---

## Risk Assessment

**Low Risk:**
- Feature renames are self-contained
- All references are in tracked files
- Profile generation is automated
- Validation catches broken references

**Testing Plan:**
1. Rename features
2. Update all references
3. Run validation (should show 70/70 pass)
4. Generate test profile (e.g., `quarto-lecture-full`)
5. Verify Dockerfile generation works

---

## Decision Required

**Approve renames?**
- [ ] ✅ Proceed with HIGH priority renames (4-5 features)
- [ ] ⏸️ Review MEDIUM priority renames first
- [ ] ❌ Keep current names

**Implementation timeline:**
- Immediate (single commit with all changes)
- Phased (commit per category)
- Defer (keep for future cleanup)
