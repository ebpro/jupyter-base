# Cleanup & Restructuring Proposal

## Executive Summary

The codebase has accumulated significant technical debt with **dual systems** (profiles, generators), **unused legacy features**, and **unclear build flow**. This proposal outlines a systematic cleanup to improve maintainability, reduce complexity, and make the system easier to understand.

---

## Problems Identified

### 1. **Dual Profile Systems** 🔴 CRITICAL
- **Problem:** Profiles exist in TWO places:
  - `profiles/` - Hand-written text files (legacy?)
  - `profiles/matrix/*.yaml` - YAML-based matrix profiles (newer?)
  - **CONFUSION:** Which one is source of truth? Both are used!

- **Impact:**
  - Developer must know which profiles use which system
  - Changes must be made in the right place
  - `quarto-lecture-full` exists in BOTH locations with DIFFERENT content

- **Evidence:**
  ```
  profiles/quarto-lecture-full          # Text file (has old features)
  profiles/matrix/quarto-lecture.yaml   # Matrix YAML (has new features)
  generated/profiles/quarto-lecture-full # Generated from matrix
  ```

### 2. **Dual Generator Scripts** ✅ RESOLVED (Phase 2)
- **Problem:** Two generators for matrix profiles:
  - `scripts/generate-profiles-matrix.sh` (bash, partial implementation) - DELETED
  - `scripts/generate-profiles-matrix.py` (python, full implementation) - KEPT

- **Resolution:**
  - Removed bash generator script
  - Python generator is the single source of truth
  - All profile generation uses Python script

### 3. **Unused/Misleading Features** 🟡 MEDIUM
- `docker-cli-helper` - Only creates group, NO actual docker CLI binary
- Legacy features in `.devcontainer/features/` that may not be used

### 4. **Complex Dependency Resolution** 🟡 MEDIUM
- Feature dependency expansion happens via `expand-feature-deps.py`
- Bundles should expand to their dependencies, but tracking is opaque
- No clear validation that bundles are being expanded properly

### 5. **37 Scripts in scripts/** 🟡 MEDIUM
- Many scripts with unclear relationships
- Some may be legacy/unused
- No clear "main workflow" vs "utility" distinction

### 6. **Misleading .devcontainer/ Directory** 🔴 CRITICAL
- **Problem:** This project BUILDS devcontainers, it's NOT a devcontainer itself
- **Current structure:**
  ```
  .devcontainer/features/     # 72 features for building OTHER containers
  ```
- **Impact:**
  - Confusing name suggests this repo uses devcontainers
  - IDE/tools may try to open THIS as a devcontainer
  - Non-standard location for build components

- **Solution:** Move to `features/` at top level

### 7. **Artefacts Directory Chaos** 🟡 MEDIUM
- **Problem:** Multiple purposes mixed in one directory:
  ```
  Artefacts/
    apt_packages.base          # Build input (lists)
    requirements.txt           # Build input (Python deps)
    environment.yml            # Build input (conda env)
    checksums.json             # Build verification
    toolcache/                 # GENERATED - prebaked downloads
    features/                  # Feature-specific artefacts
    conda/                     # Conda config files
    TeXLive                    # Static data
  ```

- **Impact:**
  - Hard to distinguish inputs from outputs
  - `toolcache/` is GENERATED but lives alongside source files
  - Unclear which files should be in git vs .gitignore

### 8. **Scattered Helper Code** 🟡 MEDIUM
- **Problem:** Helper functions in multiple places:
  ```
  shared/_lib/helpers.sh              # Shared library
  scripts/feature_helpers.sh          # Feature helpers
  scripts/lib-build.sh                # Build library
  .devcontainer/features/_lib/        # Feature library
  ```

- **Impact:**
  - Duplication and confusion about which to use
  - `shared/` should be analyzed alongside `scripts/`

### 9. **Generated Files Not in generated/** 🟡 MEDIUM
- **Problem:** Generated content scattered across repo:
  ```
  Dockerfile.generated                    # Generated (root)
  docker-bake.generated.hcl              # Generated (root)
  devcontainer.generated.json            # Generated (root)
  Artefacts/toolcache/                   # Generated (wrong place!)
  generated/profiles/                    # Generated (correct)
  build-artifact.json                    # Generated (root)
  image-digest.txt                       # Generated (root)
  ```

- **Impact:**
  - Hard to .gitignore generated files properly
  - Unclear what's source vs output
  - Cluttered root directory

---

## Proposed Cleanup (Phased)

### Phase 0: Directory Structure Rationalization 🎯 **DO FIRST**

**Goal:** Logical, predictable directory layout

**Action:**

1. **Move features to top level:**
   ```bash
   mv .devcontainer/features features/
   # Update all references in scripts
   ```
   - This is a BUILD TOOL repo, not a devcontainer
   - Makes features/ a peer of profiles/, scripts/

2. **Separate Artefacts by purpose:**
   ```
   # NEW STRUCTURE:
   inputs/                      # Build inputs (committed to git)
     apt-packages/
       base.txt
       extra.txt
     conda/
       environment.yml
       condarc
     python/
       requirements.txt
     static/
       TeXLive
       codeserver_extensions

   artefacts/                   # Feature-specific static artefacts (committed)
     java-kernel/
       checksums.json
     prompt-helpers/
       checksums.json
     quarto/
       checksums.json
       versions.json

   generated/                   # ALL generated content (.gitignore)
     toolcache/                 # Prebaked downloads
     profiles/                  # Expanded profiles
     dockerfiles/               # Generated Dockerfiles
     bake/                      # Generated bake files
     build-artifacts/           # Build outputs
   ```

3. **Consolidate helper libraries:**
   ```
   scripts/
     lib/                       # Shared library code
       helpers.sh               # From shared/_lib/
       build.sh                 # From lib-build.sh
       features.sh              # From feature_helpers.sh
     core/                      # Main generators
     validation/                # Validators
     utilities/                 # Support tools

   features/
     _lib/                      # Keep - used at image build time
   ```

4. **Move ALL generated files to generated/:**
   ```bash
   # Move build outputs
   mv Dockerfile.generated generated/Dockerfile
   mv docker-bake.generated.hcl generated/docker-bake.hcl
   mv devcontainer.generated.json generated/devcontainer.json
   mv build-artifact.json generated/build-artifact.json
   mv image-digest.txt generated/image-digest.txt

   # Update scripts to write to generated/
   # Update .gitignore to ignore generated/
   ```

**Benefits:**
- Crystal clear: inputs vs outputs vs generated
- IDE won't try to open this as a devcontainer
- Easier to gitignore generated content
- Predictable file locations

**Breaking changes:**
- All scripts must be updated
- CI workflows need path updates
- External tools referencing paths will break

**Estimated effort:** 4-6 hours

---

### Phase 1: Profile System Consolidation 🎯

**Goal:** Single source of truth for profiles

**Action:**
1. **Decision:** Use matrix YAML as primary format
   - More expressive (services, matrix expansion, options)
   - Already used by quarto-lecture profiles
   - Better for complex profiles

2. **Migrate remaining text profiles to matrix YAML:**
   ```
   profiles/base          → profiles/matrix/base.yaml
   profiles/full          → profiles/matrix/full.yaml
   profiles/python-db     → profiles/matrix/python-db.yaml
   profiles/web-dev       → profiles/matrix/web-dev.yaml
   profiles/kotlin        → profiles/matrix/kotlin.yaml
   # etc...
   ```

3. **Delete** `profiles/` text files after migration
4. **Keep** `profiles/matrix/` as THE profile directory
5. **Update** docs to reference matrix YAML exclusively

**Benefits:**
- ONE place to look for profile definitions
- Consistent syntax across all profiles
- Easier to understand what a profile includes

**Breaking changes:**
- External references to `profiles/quarto-lecture-full` must change to `generated/profiles/quarto-lecture-full`
- Build commands stay the same (they use generated profiles anyway)

---

### Phase 2: Generator Simplification ✅ COMPLETED

**Goal:** Single profile generator

**Completed Actions:**
1. ✅ **Deleted** `scripts/generate-profiles-matrix.sh` (bash, incomplete)
2. ✅ **Kept** `scripts/generate-profiles-matrix.py` (python, full-featured)
3. ✅ **Verified** Python generator works for all YAML matrices

**Results:**
- Single source of truth for profile generation
- Removed 81 lines of redundant bash code
- Python generator handles all profile variants correctly
- No naming change needed - "matrix" clarifies it generates from YAML matrices

---

### Phase 3: Feature Cleanup ✅ COMPLETED

**Goal:** Remove unused/misleading features

**Completed Actions:**
1. ✅ **Deleted** `docker-cli-helper` feature
   - Only created docker group without installing CLI
   - Replaced by proper `docker-cli` feature (installs docker-ce-cli)
   - Removed from `bundle-base-full` and `bundle-cicd-teaching`

2. ✅ **Updated** bundle dependencies:
   - `bundle-base-full`: Removed docker-cli-helper
   - `bundle-cicd-teaching`: Removed docker-cli-helper
   - Container tools now properly provided by docker-cli, docker-compose, docker-buildx

3. ✅ **Updated** analysis script bundle map to reference modern container tools

**Results:**
- Removed misleading feature that didn't install docker CLI
- Bundle dependencies now accurate
- Profile generation and Dockerfile generation verified working
- No docker-cli-helper references in generated Dockerfile
- Cleaner feature inventory

---

### Phase 4: Script Organization ✅ COMPLETED

**Goal:** Clarify script purposes and relationships

**Completed Actions:**
1. ✅ **Deleted** 4 legacy one-time migration scripts:
   - `apply_profile_renames.sh` - Profile renames (obsolete with YAML)
   - `infer_parents_from_prefixes.py` - Hierarchical parent inference (obsolete)
   - `fix_feature_jsons.py` - Feature JSON normalization (one-time)
   - `fix-feature-shebangs.sh` - Shebang fixes (one-time)

2. ✅ **Organized** scripts into subdirectories:
   ```
   scripts/
     ├── validate/       # Validation scripts (5 scripts)
     ├── test/           # Testing scripts (3 scripts)
     ├── features/       # Feature management (2 scripts)
     ├── utils/          # Utilities (9 scripts)
     ├── analysis/       # Analysis tools (2 scripts)
     ├── lib/            # Shared libraries (3 scripts)
     └── (root)          # Core build scripts (8 scripts)
   ```

3. ✅ **Updated** all script references across codebase
4. ✅ **Verified** profile generation and build workflow still work

**Results:**
- Removed 4 obsolete scripts
- 29 scripts organized into logical categories
- All path references updated (build.sh, workflows, docs)
- Core build scripts remain easily accessible in scripts/
- Better organization without breaking existing workflows
- Clear separation of concerns
- Better onboarding for new contributors

---

### Phase 5: Build Flow Documentation 🎯

**Goal:** Crystal-clear understanding of build process

**Action:**
1. **Create** `docs/BUILD_FLOW.md`:
   ```mermaid
   graph TD
     A[profiles/matrix/*.yaml] -->|generate-profiles.py| B[generated/profiles/*]
     B -->|generate-dockerfile.sh| C[Dockerfile.generated]
     B -->|expand-feature-deps.py| D[Feature list with deps]
     D -->|generate-dockerfile.sh| C
     C -->|docker buildx bake| E[Multi-arch images]
   ```

2. **Document** each major step:
   - Profile expansion
   - Feature dependency resolution
   - Bundle expansion
   - Dockerfile generation
   - Multi-arch build

3. **Add** troubleshooting section

---

## Immediate Action Plan (What to do NOW)

**For container dev tools issue:**

1. ✅ Features created (docker-cli, docker-compose, dive, etc.)
2. ✅ Bundle created (bundle-container-dev)
3. ✅ Matrix profile updated (quarto-lecture.yaml)
4. ✅ Profile regenerated with Python script
5. ⏳ **NEXT:** Verify bundle expansion works

**Test bundle expansion:**
```bash
# Check if bundle-container-dev expands to all dependencies
echo "bundle-container-dev" | python3 scripts/expand-feature-deps.py
# Should output: docker-cli docker-compose docker-buildx podman dive trivy hadolint buildah skopeo ctop
```

If expansion works, regenerate Dockerfile:
```bash
./scripts/generate-dockerfile.sh --profile quarto-lecture-full
# Check that all dev tools are in Dockerfile.generated
grep -E "docker-cli|dive|trivy|hadolint" Dockerfile.generated
```

If expansion DOESN'T work → bundle dependency resolution is broken

---

## Decision Points

**For Bruno to decide:**

1. **Profile format migration:** Agree to migrate all profiles to matrix YAML?
   - ✅ Yes → Phase 1 can proceed
   - ❌ No → Keep dual system (not recommended)

2. **Breaking changes tolerance:**
   - Are external systems referencing `profiles/` directly?
   - Can we rename/move things?

3. **Timeline:**
   - Do this cleanup NOW before adding more features?
   - Or defer to after current work?

4. **Scope:**
   - Full cleanup (all 5 phases)?
   - Or just Phase 1-2 (profile consolidation)?

---

## Risk Assessment

**Low Risk:**
- Phase 1-2 (profile consolidation) - mostly internal changes
- Phase 3 (feature cleanup) - deleting unused code

**Medium Risk:**
- Phase 4 (script reorganization) - may break external automation

**Mitigation:**
- Make changes in feature branch
- Test all main workflows before merge
- Document migration guide for external users

---

## Estimated Effort

- **Phase 0:** 4-6 hours (directory restructure, update all paths)
- **Phase 1:** 2-3 hours (migrate ~15 profiles to YAML)
- **Phase 2:** 30 minutes (delete bash script, rename Python)
- **Phase 3:** 1-2 hours (audit features, delete unused)
- **Phase 4:** 2-3 hours (reorganize scripts, update paths)
- **Phase 5:** 1 hour (write documentation)

**Total:** ~2 days of focused work

**If doing incrementally:**
- Phase 0 alone: ~1 day (but enables cleaner future work)

---

## Recommendation

**START WITH:**
1. Fix immediate issue (verify bundle expansion)
2. Test build with new container dev tools
3. If that works, propose Phase 1 cleanup as next task

**DEFER:**
- Large-scale script reorganization (Phase 4) until after critical features land
- Can be done incrementally

**PRIORITY ORDER:**
1. **Phase 0 (directory restructure)** - Foundation for everything else
2. Fix current build (container tools) - unblock immediate work
3. Phase 1 (profile consolidation) - eliminate dual systems
4. Phase 2 (generator simplification) - one generator to rule them all
5. Phase 3 (feature cleanup) - remove dead code
6. Phase 4 (script organization) - categorize and document
7. Phase 5 (documentation) - nice-to-have

**Alternative: Incremental approach**
- Do Phase 0 directory structure FIRST (breaking but necessary)
- Then proceed with current work
- Circle back to Phase 1-5 later

---

## Next Steps

**Immediate (today):**
```bash
# Verify bundle expansion works
echo "bundle-container-dev" | python3 scripts/expand-feature-deps.py

# If it works, regenerate and build
./scripts/generate-dockerfile.sh --profile quarto-lecture-full
./build.sh --profile quarto-lecture-full --load

# Test in container
docker run --rm ghcr.io/ebpro/solen:quarto-lecture-full-develop bash -c "docker --version && dive --version && trivy --version"
```

**This week:**
- Decide on cleanup scope
- Start Phase 1 if approved

---

## Questions for Bruno

1. **Phase 0 directory restructure:** Do this FIRST before any other work?
   - ✅ Yes → Breaking changes but clean foundation
   - ❌ No → Work around current structure

2. **Breaking changes acceptable?**
   - Can we move `.devcontainer/features` → `features/`?
   - Can we reorganize `Artefacts/` into `inputs/` + `artefacts/` + `generated/toolcache/`?
   - Are CI/external tools tightly coupled to current paths?

3. **Artefacts separation priority:**
   - Critical to separate inputs/outputs now?
   - Or acceptable to keep mixed structure?

4. **Timeline decision:**
   - Option A: **Do Phase 0 now** (1 day, then continue with features)
   - Option B: **Defer cleanup** (finish container tools, cleanup later)
   - Option C: **Incremental** (Phase 0 this week, rest over time)

5. **Scope confirmation:**
   - Full cleanup (all phases)?
   - Just critical items (Phase 0, 1, 2)?
   - Minimal (just fix immediate issues)?

---

## Detailed Phase 0 Migration Plan

### Step 1: Features Directory (30 min)

```bash
# Create feature branch
git checkout -b refactor/directory-structure

# Move features
mv .devcontainer/features features

# Update all script references
find scripts -type f -name "*.sh" -o -name "*.py" | xargs sed -i '' 's|\.devcontainer/features|features|g'

# Update Dockerfile generation
sed -i '' 's|\.devcontainer/features|features|g' scripts/generate-dockerfile.sh

# Test
./scripts/generate-dockerfile.sh --profile quarto-lecture-full
```

### Step 2: Artefacts Reorganization (2 hours)

```bash
# Create new structure
mkdir -p inputs/{apt-packages,conda,python,static}
mkdir -p artefacts
mkdir -p generated/toolcache

# Move input files
mv Artefacts/apt_packages* inputs/apt-packages/
mv Artefacts/conda/* inputs/conda/
mv Artefacts/requirements.txt inputs/python/
mv Artefacts/environment.yml inputs/conda/
mv Artefacts/TeXLive inputs/static/
mv Artefacts/codeserver_extensions inputs/static/

# Move feature-specific artefacts
mv Artefacts/features/* artefacts/

# Move generated toolcache
mv Artefacts/toolcache/* generated/toolcache/

# Keep checksums/metadata at top level for now
mv Artefacts/checksums.json .
mv Artefacts/tool-metadata.json .
mv Artefacts/versions.json .

# Remove old directory
rmdir Artefacts

# Update scripts
find scripts -type f | xargs sed -i '' 's|Artefacts/toolcache|generated/toolcache|g'
find scripts -type f | xargs sed -i '' 's|Artefacts/apt_packages|inputs/apt-packages|g'
```

### Step 3: Generated Files Consolidation (1 hour)

```bash
# Move generated files
mv Dockerfile.generated generated/Dockerfile
mv docker-bake.generated.hcl generated/docker-bake.hcl
mv devcontainer.generated.json generated/devcontainer.json
mv build-artifact.json generated/ 2>/dev/null || true
mv image-digest.txt generated/ 2>/dev/null || true

# Update build.sh
sed -i '' 's|Dockerfile\.generated|generated/Dockerfile|g' build.sh
sed -i '' 's|docker-bake\.generated\.hcl|generated/docker-bake.hcl|g' build.sh

# Update generators
sed -i '' 's|OUT="Dockerfile.generated"|OUT="generated/Dockerfile"|g' scripts/generate-dockerfile.sh
sed -i '' 's|"docker-bake.generated.hcl"|"generated/docker-bake.hcl"|g' scripts/generate-bake.sh
```

### Step 4: Helper Libraries Consolidation (1 hour)

```bash
# Create scripts/lib
mkdir -p scripts/lib

# Move libraries
mv shared/_lib/helpers.sh scripts/lib/
mv scripts/lib-build.sh scripts/lib/build.sh
mv scripts/feature_helpers.sh scripts/lib/features.sh

# Remove empty shared directory
rm -rf shared

# Update references
find scripts -type f | xargs sed -i '' 's|shared/_lib/helpers\.sh|scripts/lib/helpers.sh|g'
find scripts -type f | xargs sed -i '' 's|lib-build\.sh|lib/build.sh|g'
```

### Step 5: Update .gitignore (15 min)

```bash
cat >> .gitignore <<'EOF'

# Generated content
/generated/
!generated/profiles/.gitkeep
/generated/toolcache/
/generated/Dockerfile
/generated/docker-bake.hcl
/generated/devcontainer.json
/generated/build-artifact.json
/generated/image-digest.txt
EOF
```

### Step 6: Validation (30 min)

```bash
# Test profile generation
python3 scripts/generate-profiles-matrix.py --matrix profiles/matrix/quarto-lecture.yaml --out generated/profiles --prefix ""

# Test Dockerfile generation
./scripts/generate-dockerfile.sh --profile quarto-lecture-full

# Test build (local)
./build.sh --profile quarto-lecture-full --load

# Verify paths in generated files
grep -r "\.devcontainer/features" generated/
grep -r "Artefacts/" generated/
# Should return nothing
```

### Step 7: Update Documentation (30 min)

Update these files with new paths:
- README.md
- DEVELOPER.md
- LAYOUT.md
- All feature install.sh scripts that reference paths

### Step 8: CI/CD Updates

Check and update:
- `.github/workflows/*.yml` - Update all path references
- `build.sh` - Verify all paths
- Any external automation

---

## Migration Safety Checklist

Before starting:
- [ ] Create feature branch
- [ ] Backup current working state
- [ ] Document current CI/CD setup
- [ ] List all external tools that reference paths

During migration:
- [ ] Move files systematically (one category at a time)
- [ ] Update scripts after each move
- [ ] Test after each major change
- [ ] Commit incrementally with clear messages

After migration:
- [ ] Full test suite passes
- [ ] Local build works
- [ ] CI builds work
- [ ] Documentation updated
- [ ] External tools updated (if any)

---

