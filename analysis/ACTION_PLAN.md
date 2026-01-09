# Quick Action Plan - Layer Strategy Implementation

Based on analysis of your 16 profiles with 79.7% savings potential.

## 🎯 Immediate Actions (This Week)

### 1. Validate Bundle Definitions (30 min)
```bash
# Discover all bundles
cd /Users/bruno/Documents/GitHub/solen
grep -rh "^bundle-" profiles/ | sort -u > /tmp/bundles.txt
cat /tmp/bundles.txt

# For each bundle, find what it expands to by checking feature lists
# Then update scripts/analyze-profile-features.py bundle_map
```

### 2. Generate Full Analysis (5 min)
```bash
python3 scripts/analyze-profile-features.py \
  --output analysis/feature-layers.json \
  --format both

# Review the JSON to see feature assignments
cat analysis/feature-layers.json | jq '.layers'
cat analysis/feature-layers.json | jq '.profile_plans'
```

### 3. Define Your Layer Strategy (1 hour)
Create `profiles/layer-strategy.yml` - **Start Simple:**

```yaml
# Layer Strategy v1.0 - Conservative Approach
# Build these layers in order, cache aggressively

version: "1.0"

layers:
  # Always built first, rarely changes
  base:
    priority: 1
    features:
      - user
      - base-apt
      - zsh-config
      - startup
    cache_forever: true
    
  # Core toolchains, moderate stability
  foundation:
    priority: 2
    features:
      - python-conda
      - java-sdkman
      - node
    depends_on: [base]
    cache_for: "30 days"
    
  # Higher-level stacks, built on demand
  python-dev:
    priority: 3
    features:
      - jupyter-base
      - python-lsp
    depends_on: [foundation]
    
  java-dev:
    priority: 3
    features:
      - java-jdk
      - java-maven
      - java-gradle
    depends_on: [foundation]

# Profiles declare which layers they need
profile_mapping:
  quarto-lecture-containers:
    layers: [base, foundation, python-dev, java-dev]
    specific: [quarto-cli, docker-dind, java-kernel, texlive]
    
  python-db:
    layers: [base, foundation, python-dev]
    specific: [postgresql-client]
```

## 🛠️ Implementation Plan (Next 2 Weeks)

### Week 1: Proof of Concept

**Day 1-2: Update Dockerfile Generator**
- Modify `scripts/generate-dockerfile.sh` to read layer-strategy.yml
- Generate multi-stage Dockerfile with explicit layers
- Test with 1 profile (quarto-lecture-containers)

**Day 3-4: Build & Validate**
- Build layered image locally
- Verify all features work
- Compare with current approach

**Day 5: Push to Registry**
- Tag layer images with versions
- Push to ghcr.io
- Document layer versioning strategy

### Week 2: Scale to All Profiles

**Day 1-2: Generate Strategies for All Profiles**
- Run analysis for each profile
- Create layer assignments
- Identify shared vs. unique features

**Day 3-4: Parallel Builds**
- Create `build-all-layered.sh`
- Implement parallel profile builds
- Test on subset of profiles

**Day 5: CI/CD Integration**
- Update GitHub Actions workflow
- Separate layer build job from profile jobs
- Enable matrix builds for profiles

## 📊 Success Metrics

Track these before/after:

```bash
# Build time (single profile)
Before: 10-15 min
Target: 8-12 min (first time), 2-4 min (incremental)

# Build time (all 16 profiles)
Before: 160-240 min sequential
Target: 30-45 min parallel

# Cache hit rate
Before: ~30%
Target: >80%

# Storage (all images)
Before: ~160 GB
Target: ~80 GB (50% reduction)
```

## 🚨 Risks & Mitigations

### Risk 1: Layer Coupling
**Problem:** Changing one layer forces rebuilds of dependent layers
**Mitigation:** 
- Keep base/foundation stable
- Version layers semantically
- Use feature flags for experiments

### Risk 2: Complexity Overhead
**Problem:** Multi-stage Dockerfile harder to debug
**Mitigation:**
- Keep current single-stage as fallback
- Add layer visualization tool
- Document layer dependencies clearly

### Risk 3: Build Time Regression (Cold Cache)
**Problem:** First build with layers might be slower
**Mitigation:**
- Pre-warm CI cache with layer images
- Build layers nightly in CI
- Accept 10% slower first build for 80% faster subsequent builds

## 🎓 Learning from Your Analysis

### What Worked Well
- ✅ **Universal layers identified:** base (4 features) + foundation (3 features)
- ✅ **Clear hierarchy:** Foundation depends on base
- ✅ **High savings potential:** 79.7% is excellent

### What Needs Work
- ⚠️ **Large misc layer:** 17 features uncategorized
  - Action: Complete bundle expansion
  - Accept: Some features are truly specialized
- ⚠️ **Many small specialized stacks:** 8 layers with 1-3 features each
  - Action: Consider consolidating into "dev-tools" mega-layer
  - Or: Keep separated for flexibility (recommended)

### Key Insight: Your Profiles Are Diverse
- 40 features across 16 profiles = 2.5 features per profile average
- This is GOOD - means flexible, composable system
- Layer sharing helps less than in monolithic approach
- But **incremental rebuilds benefit massively**

## 💡 Pro Tips

### Tip 1: Version Your Layers
```dockerfile
FROM ghcr.io/ebpro/solen-base:1.2.0 AS base
FROM ghcr.io/ebpro/solen-foundation:2.1.5 AS foundation
FROM ghcr.io/ebpro/solen-python-dev:1.8.3 AS python-dev
```

### Tip 2: Layer Health Checks
```bash
# scripts/verify-layer.sh
docker run --rm solen-base:latest bash -c "
  which zsh && \
  test -f /opt/solen/_lib/helpers.sh && \
  echo 'Base layer: ✅'
"
```

### Tip 3: Change Detection
```bash
# Only rebuild layers where features changed
git diff HEAD~1 --name-only | grep "features/" | cut -d/ -f3 | sort -u
# Output: java-jdk, jupyter-base
# → Rebuild java-dev layer and jupyter-stack layer only
```

### Tip 4: Cache Key Strategy
```dockerfile
# Use feature checksums for cache keys
COPY features/python-conda/install.sh /tmp/feature-python-conda.sh
RUN sha256sum /tmp/feature-python-conda.sh > /tmp/cache-key.txt
# Cache invalidates only when feature content changes
```

## 📈 Roadmap

### Phase 1: Static Layers (Current)
- Manually define layers in layer-strategy.yml
- Update Dockerfile generator
- Build sequentially with caching

### Phase 2: Dynamic Analysis (Next Month)
- Use analyze-profile-features.py output directly
- Auto-generate layer-strategy.yml
- Optimize layer boundaries based on usage patterns

### Phase 3: Smart Rebuilds (Q1 2026)
- Detect changed features via git diff
- Rebuild only affected layers
- Parallel profile builds automatically

### Phase 4: Layer Marketplace (Future)
- Publish stable layers as versioned releases
- Community profiles can reference standard layers
- Semantic versioning for layer contracts

## 🔗 Next Steps

1. **Now:** Review analysis/README.md for detailed guide
2. **Today:** Update bundle definitions in script
3. **This Week:** Create layer-strategy.yml
4. **Next Week:** Modify Dockerfile generator
5. **End of Month:** Full parallel build system

Questions? Issues? Check analysis/README.md or ping in chat!
