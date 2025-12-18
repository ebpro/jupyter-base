# Feature Architecture Analysis & Best Practices

**Date**: 2025-12-18  
**Context**: Phase 2 optimization - validating feature separation before implementing caching

---

## Current Feature Organization

### Java/JVM Ecosystem (5 features)

```
java-sdkman (foundation)
    ├── java-devtools (JDK + build tools)
    ├── graalvm (alternative JVM)
    ├── kotlin (Kotlin compiler + kernel)
    └── java-kernel (IJava Jupyter kernel)
```

**Dependencies:**
- `java-sdkman` → depends on `user`
- `java-devtools` → depends on `java-sdkman`
- `graalvm` → depends on `java-sdkman`
- `kotlin` → depends on `java-sdkman`
- `java-kernel` → depends on `java-devtools` + `jupyter-kernels`

**What each provides:**
- `java-sdkman`: SDKMAN framework (+ optional Maven/Gradle)
- `java-devtools`: **JDK installation** (+ optional Maven/Gradle/JDTLS)
- `graalvm`: GraalVM distribution (via SDKMAN)
- `kotlin`: Kotlin compiler (via SDKMAN) + optional Kotlin kernel
- `java-kernel`: IJava kernel for Jupyter

---

## Issues Identified

### 1. ❌ **Overlap: Maven/Gradle in TWO features**

Both `java-sdkman` and `java-devtools` can install Maven and Gradle:

**java-sdkman/install.sh (lines 124-136):**
```bash
if is_true "$INSTALL_MAVEN"; then
  echo "sdk install maven || true" >> "$CAND_SCRIPT"
fi
if is_true "$INSTALL_GRADLE"; then
  echo "sdk install gradle || true" >> "$CAND_SCRIPT"
fi
```

**java-devtools/install.sh (lines 140-165):**
```bash
if [ "$INSTALL_MAVEN" = "true" ]; then
  echo "java-devtools: installing Maven via SDKMAN"
  su - ${NB_USER:-jovyan} -s /bin/bash -lc "... sdk install maven" || true
fi
if [ "$INSTALL_GRADLE" = "true" ]; then
  echo "java-devtools: installing Gradle via SDKMAN"
  su - ${NB_USER:-jovyan} -s /bin/bash -lc "... sdk install gradle" || true
fi
```

**Problem**: Duplication, unclear which feature is responsible, potential conflicts.

### 2. ⚠️ **Unclear Responsibility: java-devtools name vs. function**

**Name suggests**: "Development tools" (Maven, Gradle, LSP, etc.)  
**Actually does**: **Installs JDK** (primary function)

**From java-devtools/install.sh line 25:**
```bash
install_jdk() {
  local ver="$1"
  # ... 100+ lines of JDK version selection and installation
}
```

The JDK installation is the **main purpose**, but the name implies it's about tooling around Java.

### 3. ⚠️ **Inconsistent dependency declarations**

- `graalvm` depends on `java-sdkman` (correct - uses SDKMAN to install GraalVM)
- `kotlin` depends on `java-sdkman` (correct - uses SDKMAN to install Kotlin)
- `java-kernel` depends on `java-devtools` (correct - needs JDK to run)

But if someone wants GraalVM + Java kernel, they get:
```
java-sdkman → graalvm (installs GraalVM as the JDK)
java-sdkman → java-devtools (installs Temurin JDK)
```

**Result**: Two JDKs installed! GraalVM gets overridden or coexists awkwardly.

### 4. ✅ **Good Separation**: kotlin and graalvm as separate features

These are correctly separated - they're alternative JVM distributions/languages that use SDKMAN.

---

## Recommended Refactoring

### Option A: **Split java-devtools into smaller features** (BEST)

**New structure:**
```
java-sdkman (SDKMAN framework only)
    ├── java-jdk (JDK installation via SDKMAN)
    ├── java-maven (Maven via SDKMAN)
    ├── java-gradle (Gradle via SDKMAN)
    ├── java-lsp (JDTLS language server)
    ├── graalvm (GraalVM distribution)
    ├── kotlin (Kotlin compiler)
    └── java-kernel (IJava kernel, depends on java-jdk OR graalvm)
```

**Benefits:**
- ✅ Single Responsibility Principle
- ✅ Composable (install only what you need)
- ✅ No duplication
- ✅ Clear ownership
- ✅ Better caching (Maven layer separate from JDK layer)

**Migration:**
- Create new features: `java-jdk`, `java-maven`, `java-gradle`
- Update `java-devtools` to be a "meta-feature" that includes all of them (for backward compatibility)
- Update profiles to use granular features

### Option B: **Keep current but fix overlaps** (EASIER)

**Changes:**
```
java-sdkman: Remove Maven/Gradle installation (keep only SDKMAN framework)
java-devtools: Keep Maven/Gradle + JDK (rename to java-stack or java-jdk-tools)
graalvm: Add option to skip JDK if GraalVM is the primary Java
kotlin: Keep as-is
java-kernel: Make it work with java-devtools OR graalvm
```

**Benefits:**
- ✅ Minimal changes
- ✅ Backward compatible
- ✅ Fixes duplication

**Drawbacks:**
- ❌ Still violates Single Responsibility
- ❌ java-devtools still does too much

### Option C: **Rename and clarify** (MINIMAL)

**Changes:**
```
java-sdkman: Rename to java-sdk-manager (clarity)
java-devtools: Rename to java-jdk-devtools or java-stack (reflects JDK install)
  - Remove INSTALL_MAVEN/INSTALL_GRADLE from java-sdkman
  - Keep only in java-devtools
```

**Benefits:**
- ✅ Minimal code changes
- ✅ Clearer naming

**Drawbacks:**
- ❌ Breaking change (profile updates needed)
- ❌ Still has overlap issues

---

## Recommendation: **Option A** (Split)

### Migration Plan

#### 1. Create new granular features

**java-jdk** (new):
```json
{
  "id": "java-jdk",
  "name": "Java JDK",
  "description": "Installs Java JDK via SDKMAN (Temurin, OpenJDK, etc.)",
  "dependsOn": ["java-sdkman"],
  "provides": ["java", "javac"],
  "options": {
    "JDK_VERSION": {"type": "string", "default": "25"},
    "JDK_DISTRIBUTION": {"type": "string", "default": "temurin"}
  }
}
```

**java-maven** (new):
```json
{
  "id": "java-maven",
  "name": "Apache Maven",
  "description": "Installs Maven build tool via SDKMAN",
  "dependsOn": ["java-sdkman"],
  "provides": ["maven", "mvn"]
}
```

**java-gradle** (new):
```json
{
  "id": "java-gradle",
  "name": "Gradle Build Tool",
  "description": "Installs Gradle via SDKMAN",
  "dependsOn": ["java-sdkman"],
  "provides": ["gradle"]
}
```

#### 2. Update java-sdkman

```json
{
  "id": "java-sdkman",
  "description": "Installs SDKMAN framework for JVM tool management",
  "dependsOn": ["user"],
  "provides": ["sdkman"],
  "options": {} // Remove INSTALL_MAVEN, INSTALL_GRADLE
}
```

**install.sh**: Remove Maven/Gradle installation logic (lines 91-136)

#### 3. Update java-devtools

**Option 3a**: Make it a meta-feature (recommended)
```json
{
  "id": "java-devtools",
  "description": "Meta-feature: Installs complete Java development stack",
  "dependsOn": ["java-jdk", "java-maven", "java-gradle"],
  "provides": [] // Inherits from dependencies
}
```

**Option 3b**: Deprecate it, update all profiles to use granular features

#### 4. Update profiles

**Before:**
```yaml
@parent:10-00-dev
java-sdkman
java-devtools
@options: INSTALL_MAVEN=true;INSTALL_GRADLE=true;JDK_VERSION=25
```

**After:**
```yaml
@parent:10-00-dev
java-jdk
java-maven
java-gradle
@options: JDK_VERSION=25
```

Or keep backward compatibility:
```yaml
@parent:10-00-dev
java-devtools  # Meta-feature, installs java-jdk + maven + gradle
@options: JDK_VERSION=25
```

#### 5. Fix graalvm/java conflicts

**graalvm** should provide `java` and `javac`:
```json
{
  "id": "graalvm",
  "dependsOn": ["java-sdkman"],
  "provides": ["graalvm", "java", "javac"],
  "conflicts": ["java-jdk"]  // NEW: Explicit conflict
}
```

**java-kernel** should accept either:
```json
{
  "id": "java-kernel",
  "dependsOn": ["jupyter-kernels"],
  "dependsOnOneOf": ["java-jdk", "graalvm"]  // NEW: Alternative dependencies
}
```

---

## Impact Analysis

### Build Performance

**Current** (with java-devtools):
```
Stage: java-devtools (300MB, 3-5 min)
  - Install JDK
  - Install Maven
  - Install Gradle
```

**Proposed** (split features):
```
Stage: java-jdk (250MB, 2-3 min)
Stage: java-maven (30MB, 30 sec)
Stage: java-gradle (20MB, 30 sec)
```

**Cache Benefits:**
- Profiles with java-jdk but without Maven share JDK cache (not possible today)
- Profiles with different JDK versions can share Maven/Gradle cache
- Estimated: **15-20% better cache hit rate** for Java profiles

### Profile Updates

**Affected profiles** (11 total):
```
11-00-dev-java-sdk
11-01-dev-java-latest
11-02-dev-java-ea
11-10-dev-java-8
11-11-dev-java-21
11-12-dev-java-25
11-20-dev-java-graal
11-30-dev-kotlin
20-02-quarto-lecture-dev-java-25
20-20-quarto-lecture-full
50-00-full
```

**Migration effort**: 1-2 hours (simple find/replace)

---

## Decision Matrix

| Criteria | Option A (Split) | Option B (Fix) | Option C (Rename) |
|----------|-----------------|----------------|-------------------|
| **Separation of Concerns** | ✅✅✅ Excellent | ⚠️ OK | ⚠️ OK |
| **Caching Optimization** | ✅✅✅ Best | ⚠️ Limited | ❌ None |
| **Migration Effort** | ⚠️ Medium (2-3 hrs) | ✅ Low (1 hr) | ✅ Low (30 min) |
| **Backward Compatibility** | ✅ Can preserve | ✅ Yes | ⚠️ Breaking |
| **Maintainability** | ✅✅✅ Excellent | ⚠️ OK | ⚠️ OK |
| **Composability** | ✅✅✅ Excellent | ⚠️ Limited | ⚠️ Limited |

**Recommendation**: **Option A** - The extra 2 hours of migration work pays off with:
- 15-20% better cache performance (Phase 2 goal)
- Cleaner architecture for future features
- Easier to reason about dependencies
- Better aligns with "Phase 2: Layer Caching" goals

---

## Next Steps

1. **Decide** on approach (A, B, or C)
2. **If Option A**:
   - Create new features: java-jdk, java-maven, java-gradle
   - Update java-sdkman (remove build tool installation)
   - Create java-devtools as meta-feature OR deprecate
   - Update all 11 Java profiles
   - Add "conflicts" and "dependsOnOneOf" support to validator
3. **Re-validate** entire system
4. **Continue** with Phase 2 caching implementation

---

## Open Questions

1. Should we support `conflicts` and `dependsOnOneOf` in feature.json?
2. Should java-devtools become a meta-feature or be deprecated?
3. Do we need java-lsp as a separate feature, or keep it in java-jdk?
4. Should we version this refactoring (e.g., v2 feature format)?

