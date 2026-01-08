# Multi-Stage Build Architecture

**Goal**: Reduce CI build times by 60-80% through shared intermediate stages and BuildKit cache optimization.

**Status**: Design Phase (Phase 2, Task 2)

---

## Analysis Results

Based on [analyze-build-patterns.py](../scripts/analyze-build-patterns.py), we identified:

- **21 total profiles** in the repository
- **90% of profiles** (19/21) would benefit from shared stages
- **Estimated cache savings**: ~7.7GB across all profiles
- **Target**: 60-80% build time reduction for cached profiles

### Feature Usage Patterns

| Feature Category | Usage | Size | Profiles Affected |
|-----------------|-------|------|-------------------|
| **Universal** (base, zsh, etc.) | 100% | ~200MB | 21/21 |
| **node** | 90.5% | ~100MB | 19/21 |
| **python-base** | 95.2% | ~100MB | 20/21 |
| **java-sdkman** | 52.4% | ~50MB | 11/21 |
| **java-devtools** | 42.9% | ~300MB | 9/21 |
| **python-conda** | 23.8% | ~500MB | 5/21 |

---

## Proposed Stage Architecture

### Stage Hierarchy

```
┌─────────────────────────────────────────────────────┐
│  base-ubuntu (FROM ubuntu:22.04)                    │
│  - OS base layer                                     │
└─────────────────────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────┐
│  stage-foundation (FROM base-ubuntu)                │
│  - user (jovyan)                                     │
│  - base-apt (system packages)                        │
│  - zsh-config (shell environment)                    │
│  - git-lfs, gh-cli (version control)                 │
│  - docker-cli-helper                                 │
│  - prompt-helpers, startup                           │
│  ✓ Used by 100% of profiles                         │
└─────────────────────────────────────────────────────┘
                        │
        ┌───────────────┼───────────────┐
        ▼               ▼               ▼
┌─────────────┐  ┌─────────────┐  ┌─────────────┐
│stage-node   │  │stage-python │  │stage-java   │
│- node       │  │- python-base│  │- java-sdkman│
│- npm        │  │- pip        │  │- java-dev.. │
│             │  │- python-conda│ │- maven/gradle│
│19 profiles  │  │5 profiles   │  │11 profiles  │
│(90%)        │  │(24%)        │  │(52%)        │
└─────────────┘  └─────────────┘  └─────────────┘
        │               │               │
        └───────────────┼───────────────┘
                        ▼
            ┌───────────────────────┐
            │ profile-specific      │
            │ (final FROM stage)    │
            │ - Additional features │
            │ - Profile customization│
            └───────────────────────┘
```

### Stage Definitions

#### 1. `stage-foundation` (Universal Base)

**Purpose**: Foundation for all profiles (100% usage)

**Features included**:
```dockerfile
# Core system setup
RUN install-feature user
RUN install-feature base-apt
RUN install-feature zsh-config
RUN install-feature prompt-helpers
RUN install-feature startup
RUN install-feature gh-cli
RUN install-feature git-lfs
RUN install-feature docker-cli-helper
```

**Benefits**:
- Single shared layer for all profiles
- ~200MB cached layer
- Includes all universal tooling

**Cache strategy**: Always cache, update only when base features change

---

#### 2. `stage-node` (Node.js Stack)

**Purpose**: Node.js development environment (90.5% usage)

**Inherits from**: `stage-foundation`

**Additional features**:
```dockerfile
FROM stage-foundation AS stage-node
RUN install-feature node
RUN install-feature lsp-tools  # Often paired with node
RUN install-feature dev-tools
```

**Benefits**:
- 19/21 profiles reuse this stage
- ~100MB cached layer (node + npm)
- Includes LSP for editor support

**Used by profiles**:
- `10-00-dev` (base development)
- `40-00-codeserver` (code-server)
- All `11-XX-dev-java-*` (Java + Node combo)
- All data science profiles (Jupyter + Node)

---

#### 3. `stage-python` (Python Conda Stack)

**Purpose**: Data science Python environment (23.8% usage)

**Inherits from**: `stage-foundation`

**Additional features**:
```dockerfile
FROM stage-foundation AS stage-python
RUN install-feature python-base
RUN install-feature python-conda  # Heavy: ~500MB
RUN install-feature pip-requirements
```

**Benefits**:
- 5 profiles reuse this stage
- ~600MB cached layer (python-base + conda)
- Miniforge installation is expensive

**Used by profiles**:
- `20-00-data-science`
- `20-01-quarto-lecture`
- `20-02-quarto-lecture-dev-java-25`
- `20-20-quarto-lecture-full`
- `50-00-full`

---

#### 4. `stage-java` (Java/JVM Stack)

**Purpose**: JVM development environment (52.4% usage)

**Inherits from**: `stage-foundation`

**Additional features**:
```dockerfile
FROM stage-foundation AS stage-java
RUN install-feature java-sdkman    # ~50MB
RUN install-feature java-devtools  # ~300MB (JDK + Maven)
```

**Benefits**:
- 11 profiles reuse this stage
- ~350MB cached layer (SDKMAN + JDK)
- Includes build tools (Maven, Gradle)

**Used by profiles**:
- All `11-XX-dev-java-*` profiles (11 variants)
- Some data science profiles with Java kernel

---

#### 5. `stage-python-java` (Data Science + JVM)

**Purpose**: Combined Python/Java for data science (14% usage)

**Inherits from**: `stage-python`

**Additional features**:
```dockerfile
FROM stage-python AS stage-python-java
RUN install-feature java-sdkman
RUN install-feature java-devtools
RUN install-feature jupyter-kernels  # Includes Java kernel
```

**Benefits**:
- 3 profiles reuse this stage
- Avoids rebuilding Python stack for Java profiles
- Optimal for data science with JVM

**Used by profiles**:
- `20-02-quarto-lecture-dev-java-25`
- `20-20-quarto-lecture-full`
- `50-00-full`

---

## Build Stage Selection Algorithm

### Profile → Stage Mapping

The generator should automatically select the appropriate base stage:

```python
def select_base_stage(profile_features: list[str]) -> str:
    """
    Select optimal base stage based on profile features.
    Maximizes cache reuse by choosing the most specific shared stage.
    """
    has_python_conda = 'python-conda' in profile_features
    has_java = 'java-sdkman' in profile_features or 'java-devtools' in profile_features
    has_node = 'node' in profile_features

    # Decision tree (most specific first)
    if has_python_conda and has_java:
        return 'stage-python-java'  # Combined stack
    elif has_python_conda:
        return 'stage-python'        # Python-only stack
    elif has_java and has_node:
        return 'stage-node'          # Java profiles typically need node
    elif has_java:
        return 'stage-java'          # Java-only stack
    elif has_node:
        return 'stage-node'          # Node stack (most common)
    else:
        return 'stage-foundation'    # Minimal profiles
```

### Example Profile Mappings

| Profile | Selected Stage | Reason |
|---------|---------------|--------|
| `00-01-minimal` | `stage-foundation` | No heavy features |
| `10-00-dev` | `stage-node` | Has node, no Python/Java |
| `11-10-dev-java-8` | `stage-node` | Has java + node (node stage includes both) |
| `20-00-data-science` | `stage-python` | Has python-conda |
| `20-02-quarto-lecture-dev-java-25` | `stage-python-java` | Has both python-conda + java |
| `40-00-codeserver` | `stage-node` | Has node |

---

## Implementation Strategy

### Phase 1: Generator Modifications

**File**: `scripts/generate-dockerfile.sh`

1. **Detect required stage** based on expanded feature list
2. **Emit stage definitions** before profile-specific features
3. **Use `FROM <stage>` instead of `FROM base`**
4. **Filter out redundant features** (already in selected stage)

### Phase 2: Stage Definition Templates

**New file**: `scripts/stage-templates.sh`

```bash
# Define reusable stage templates
generate_foundation_stage() {
    cat <<'EOF'
# ============================================
# Stage: foundation (universal base)
# ============================================
FROM ubuntu:22.04 AS stage-foundation

# Universal features (100% of profiles)
RUN install-feature user
RUN install-feature base-apt
RUN install-feature zsh-config
RUN install-feature prompt-helpers
RUN install-feature startup
RUN install-feature gh-cli
RUN install-feature git-lfs
RUN install-feature docker-cli-helper

LABEL org.opencontainers.image.stage="foundation"
LABEL org.opencontainers.image.features="user,base-apt,zsh,git"
EOF
}

generate_node_stage() {
    cat <<'EOF'
# ============================================
# Stage: node (Node.js development)
# ============================================
FROM stage-foundation AS stage-node

RUN install-feature node
RUN install-feature lsp-tools
RUN install-feature dev-tools

LABEL org.opencontainers.image.stage="node"
LABEL org.opencontainers.image.features="node,lsp,dev-tools"
EOF
}

# Similar functions for stage-python, stage-java, stage-python-java...
```

### Phase 3: Cache Configuration

**File**: `build.sh` or `Makefile`

```bash
# Enable BuildKit inline cache
export DOCKER_BUILDKIT=1

# Build with cache exports
docker build \
  --cache-from type=registry,ref=ghcr.io/ebpro/jupyter-base:cache-foundation \
  --cache-from type=registry,ref=ghcr.io/ebpro/jupyter-base:cache-node \
  --cache-from type=registry,ref=ghcr.io/ebpro/jupyter-base:cache-python \
  --cache-from type=registry,ref=ghcr.io/ebpro/jupyter-base:cache-java \
  --cache-to type=inline \
  -t ghcr.io/ebpro/jupyter-base:${PROFILE} \
  .
```

**GitHub Actions workflow**:
```yaml
- name: Build with cache
  uses: docker/build-push-action@v5
  with:
    context: .
    push: true
    tags: ghcr.io/ebpro/jupyter-base:${{ matrix.profile }}
    cache-from: |
      type=registry,ref=ghcr.io/ebpro/jupyter-base:cache-foundation
      type=registry,ref=ghcr.io/ebpro/jupyter-base:cache-node
      type=registry,ref=ghcr.io/ebpro/jupyter-base:cache-python
      type=registry,ref=ghcr.io/ebpro/jupyter-base:cache-java
    cache-to: type=inline
```

---

## Performance Estimates

### Current Build Times (Estimated)

| Profile Type | Current Duration | Main Bottleneck |
|--------------|------------------|-----------------|
| Minimal (`00-01-minimal`) | ~5 min | Base apt + zsh |
| Dev (`10-00-dev`) | ~12 min | Node install + base |
| Java (`11-XX-dev-java-*`) | ~20 min | JDK download + compile |
| Data Science (`20-XX`) | ~25 min | Conda + packages |
| Full (`50-00-full`) | ~35 min | Everything |

### With Shared Stages (Estimated)

| Profile Type | With Cache | Speedup | Cache Source |
|--------------|-----------|---------|--------------|
| Minimal | ~2 min | 60% | stage-foundation |
| Dev | ~4 min | 67% | stage-node |
| Java | ~6 min | 70% | stage-node + java layers |
| Data Science | ~8 min | 68% | stage-python |
| Full | ~10 min | 71% | stage-python-java |

**Average improvement**: **60-80% faster builds** when cache hits

### Cache Hit Scenarios

| Scenario | Cache Hit Rate | Build Time Impact |
|----------|---------------|-------------------|
| **First build** (cold) | 0% | No improvement (baseline) |
| **Base features unchanged** | 100% foundation | ~30% faster |
| **Node updated, Python stable** | stage-python cached | ~40% faster for Python profiles |
| **Full cache hit** | All stages cached | **60-80% faster** |

---

## Maintenance & Considerations

### When to Rebuild Stages

**stage-foundation**: Rebuild when:
- Base Ubuntu image updates
- Core packages (zsh, git) update
- User setup changes

**stage-node**: Rebuild when:
- Node.js version changes (in versions.json)
- npm dependencies update

**stage-python**: Rebuild when:
- Miniforge version changes
- Base Conda packages update (environment.yml)

**stage-java**: Rebuild when:
- Default JDK version changes
- SDKMAN version updates

### Cache Invalidation Strategy

```bash
# Invalidate specific stage cache
docker build --no-cache --target stage-node ...

# Invalidate from a point forward
# (e.g., rebuild Python and everything after)
docker build --cache-from stage-foundation --no-cache-filter stage-python ...
```

### Trade-offs

**Pros**:
- ✅ 60-80% faster CI builds
- ✅ ~7.7GB cache savings
- ✅ 90% of profiles benefit
- ✅ Easier to debug (stages are testable)
- ✅ Better layer reuse across profiles

**Cons**:
- ❌ More complex Dockerfile generation
- ❌ Requires BuildKit (Docker 18.09+)
- ❌ Cache storage in registry (~2-3GB)
- ❌ Initial setup complexity
- ❌ Need to manage stage dependencies

---

## Next Steps

1. ✅ **Task 1**: Analyze build patterns (COMPLETE)
2. ✅ **Task 2**: Design multi-stage strategy (CURRENT - this document)
3. ⏳ **Task 3**: Implement in generate-dockerfile.sh
4. ⏳ **Task 4**: Configure BuildKit cache
5. ⏳ **Task 5**: Test and measure performance
6. ⏳ **Task 6**: Document for developers

---

## References

- **Analysis**: [scripts/analyze-build-patterns.py](../scripts/analyze-build-patterns.py)
- **BuildKit Cache**: https://docs.docker.com/build/cache/
- **Multi-stage builds**: https://docs.docker.com/build/building/multi-stage/
- **Audit**: [AUDIT.md](../AUDIT.md) Item #4
