# Python CLI Feature Audit

**Comprehensive comparison between legacy bash scripts and Python CLI implementation**

Generated: 2026-01-14

---

## Executive Summary

The Python CLI (`solen-cli`) is **missing critical functionality** from the legacy bash scripts:

- ❌ **No git integration** (branch, commit SHA, timestamps)
- ❌ **No docker-bake generator** (module doesn't exist)
- ❌ **No OCI container labels** (org.opencontainers.image.*)
- ❌ **No build metadata** (build date, revision)
- ❌ **No devcontainer generator** (CLI command stub exists but no implementation)
- ⚠️ **Limited feature metadata** (missing maintainers, platforms aggregation)

---

## Feature Comparison Matrix

| Feature | Bash Scripts | Python CLI | Status | Priority |
|---------|-------------|------------|--------|----------|
| **Dockerfile Generation** | ✅ Full | ✅ Implemented | ✅ **COMPLETE** | - |
| **Profile Expansion** | ✅ Parent refs | ✅ Parent refs | ✅ **COMPLETE** | - |
| **Feature Dependency Resolution** | ✅ Via Python helper | ✅ Native | ✅ **COMPLETE** | - |
| **Topological Sort** | ✅ Via Python helper | ✅ Native | ✅ **COMPLETE** | - |
| **Bundle Meta-feature Expansion** | ✅ Yes | ✅ Yes | ✅ **COMPLETE** | - |
| **BuildKit Cache Mounts** | ✅ Yes | ✅ Yes | ✅ **COMPLETE** | - |
| **Feature Options as ENV** | ✅ Yes | ✅ Yes | ✅ **COMPLETE** | - |
| **Profile Normalization** | ✅ Duplicate detection | ❌ No | ⚠️ **MISSING** | Medium |
| | | | | |
| **Git Branch Detection** | ✅ Yes | ❌ No | ❌ **MISSING** | **HIGH** |
| **Git Commit SHA** | ✅ Full + Short | ❌ No | ❌ **MISSING** | **HIGH** |
| **Git Tag Detection** | ✅ Yes | ❌ No | ❌ **MISSING** | **HIGH** |
| **Build Timestamp** | ✅ ISO 8601 UTC | ❌ No | ❌ **MISSING** | **HIGH** |
| | | | | |
| **OCI Image Labels** | ✅ Yes (3 labels) | ❌ No | ❌ **MISSING** | **HIGH** |
| - `image.created` | ✅ | ❌ | ❌ **MISSING** | **HIGH** |
| - `image.version` | ✅ | ❌ | ❌ **MISSING** | **HIGH** |
| - `image.revision` | ✅ | ❌ | ❌ **MISSING** | **HIGH** |
| - `image.source` | ❌ | ❌ | ⚠️ Both missing | Medium |
| - `image.url` | ❌ | ❌ | ⚠️ Both missing | Medium |
| **Solen Custom Labels** | ✅ Yes (3 labels) | ✅ Yes (3 labels) | ✅ **COMPLETE** | - |
| - `org.solen.vendor` | ✅ | ✅ | ✅ **COMPLETE** | - |
| - `org.solen.profile` | ✅ | ✅ | ✅ **COMPLETE** | - |
| - `org.solen.features.added` | ✅ | ✅ | ✅ **COMPLETE** | - |
| - `org.solen.features.provides` | ✅ | ✅ | ✅ **COMPLETE** | - |
| | | | | |
| **Build Args** | ✅ 2 args | ❌ No | ❌ **MISSING** | **HIGH** |
| - `GIT_SHA` | ✅ | ❌ | ❌ **MISSING** | **HIGH** |
| - `BUILD_DATE` | ✅ | ❌ | ❌ **MISSING** | **HIGH** |
| | | | | |
| **Docker Bake Generator** | ✅ Full HCL | ❌ Not implemented | ❌ **CRITICAL** | **CRITICAL** |
| - Multi-platform support | ✅ | ❌ | ❌ **MISSING** | **CRITICAL** |
| - Tag generation | ✅ Git-aware | ❌ | ❌ **MISSING** | **CRITICAL** |
| - Profile-scoped tags | ✅ | ❌ | ❌ **MISSING** | **CRITICAL** |
| - Group targets | ✅ | ❌ | ❌ **MISSING** | **CRITICAL** |
| | | | | |
| **Devcontainer Generator** | ✅ Full JSON | ❌ Not implemented | ❌ **CRITICAL** | **CRITICAL** |
| - Feature references | ✅ | ❌ | ❌ **MISSING** | **CRITICAL** |
| - Feature options | ✅ Dot notation | ❌ | ❌ **MISSING** | **CRITICAL** |
| - Container env vars | ✅ | ❌ | ❌ **MISSING** | **CRITICAL** |
| - VSCode extensions | ✅ Stub | ❌ | ❌ **MISSING** | Medium |
| | | | | |
| **Profile README Generator** | ❌ Not in bash | ✅ In CLI | ✅ **NEW** | - |
| **Feature Validation** | ❌ Separate script | ✅ In CLI | ✅ **NEW** | - |
| **Feature Analysis** | ❌ Not in bash | ✅ In CLI | ✅ **NEW** | - |

---

## Detailed Analysis

### 1. Git Integration (❌ MISSING - HIGH PRIORITY)

**What bash does:**
```bash
# build.sh lines 19-46
get_git_tag() { git describe --tags --exact-match 2>/dev/null || echo "" }
get_git_sha() { git rev-parse --short HEAD 2>/dev/null || echo "unknown" }
get_git_branch() { git rev-parse --abbrev-ref HEAD 2>/dev/null | tr '/' '-' || echo "main" }

get_version_tags() {
    local git_tag=$(get_git_tag)
    local git_sha_short=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    local git_branch=$(get_git_branch)

    if [[ -n "${git_tag}" ]]; then
        echo "${git_tag} ${git_tag}-${git_sha_short}"      # v1.2.3 v1.2.3-abc123
    elif [[ "${git_branch}" == "main" ]]; then
        echo "latest ${git_branch}-${git_sha_short}"       # latest main-abc123
    else
        echo "${git_branch} ${git_branch}-${git_sha_short}" # feat-xyz feat-xyz-abc123
    fi
}

# build.sh lines 205-232
GIT_SHA=$(get_git_sha)                                      # abc123
GIT_SHA_SHORT=$(git rev-parse --short HEAD || echo "unknown")
GIT_BRANCH=$(get_git_branch)                                # feat-xyz
FULL_GIT_SHA=$(git rev-parse HEAD || echo "unknown")        # abc123def456...
BUILD_DATE_UTC=$(date -u +'%Y%m%dT%H%M%SZ')                # 20260114T153022Z

TAGS_LIST=("${TAG1}" "${TAG2}" "${GIT_SHA_SHORT}" "build-${BUILD_DATE_UTC}")
```

**What Python CLI needs:**
- `solen/utils/git.py` module with:
  - `get_git_branch()` → str
  - `get_git_sha(short=True)` → str
  - `get_git_tag()` → str | None
  - `get_version_tags()` → tuple[str, str]
  - `is_dirty()` → bool
- Integration in Dockerfile generator to add labels
- Integration in bake generator for tag generation

**Impact:** Images cannot be traced back to source code. Critical for CI/CD.

---

### 2. OCI Container Labels (❌ MISSING - HIGH PRIORITY)

**What bash does:**
```bash
# build.sh lines 529-531
--label "org.opencontainers.image.created=$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
--label "org.opencontainers.image.version=${TAG1}"
--label "org.opencontainers.image.revision=${GIT_SHA}"
```

**What Python CLI should add to Dockerfile:**
```dockerfile
# In emit_dockerfile_header() or per-profile stage:
ARG GIT_SHA=unknown
ARG BUILD_DATE=unknown

LABEL org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.version="<primary_tag>" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.source="https://github.com/ebpro/solen" \
      org.opencontainers.image.url="https://github.com/ebpro/solen"
```

**Standards:** [OCI Image Spec - Pre-Defined Annotation Keys](https://github.com/opencontainers/image-spec/blob/main/annotations.md)

**Impact:** Metadata loss. Docker images won't be traceable in registries.

---

### 3. Build Args (❌ MISSING - HIGH PRIORITY)

**What bash does:**
```bash
# build.sh lines 527-528
--build-arg "GIT_SHA=${GIT_SHA}"
--build-arg "BUILD_DATE=$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
```

**What Python CLI needs:**
```python
# In emit_dockerfile_header():
f.write('ARG GIT_SHA=unknown\n')
f.write('ARG BUILD_DATE=unknown\n')
f.write('ARG GIT_BRANCH=unknown\n')
```

Then when building:
```bash
docker build \
  --build-arg GIT_SHA=$(git rev-parse HEAD) \
  --build-arg BUILD_DATE=$(date -u +'%Y-%m-%dT%H:%M:%SZ') \
  --build-arg GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD) \
  ...
```

**Impact:** Build-time metadata unavailable. Labels won't populate correctly.

---

### 4. Docker Bake Generator (❌ CRITICAL - NOT IMPLEMENTED)

**What bash does:** `scripts/generate-bake.sh` (100 lines)

**Features:**
1. **Multi-platform support:** `linux/amd64,linux/arm64`
2. **Git-aware tagging:** Tags derived from branch/commit
3. **Profile-scoped tags:** `<repo>/<image>:<profile-slug>-<tag>`
4. **Group targets:** `group "all" { targets = [...] }`
5. **HCL generation:** Proper docker-bake.hcl format

**Example output:**
```hcl
group "all" {
  targets = [
    "final-java-25",
    "final-quarto-lecture-full",
  ]
}

target "final-quarto-lecture-full" {
  context = "."
  dockerfile = "generated/Dockerfile"
  target = "final-quarto-lecture-full"
  platforms = [
    "linux/amd64",
    "linux/arm64",
  ]
  tags = [
    "ghcr.io/ebpro/solen:quarto-lecture-full-latest",
    "ghcr.io/ebpro/solen:quarto-lecture-full-main-49e4855",
    "ghcr.io/ebpro/solen:quarto-lecture-full-49e4855",
    "ghcr.io/ebpro/solen:quarto-lecture-full-build-20260114T153022Z",
  ]
}
```

**What Python CLI needs:**
- Create `solen/generators/bake.py`
- Implement `generate_bake(repo_root: Path, output_path: Path) -> int`
- Git integration for tag generation
- Platform normalization (amd64 → linux/amd64)
- Profile slug computation (strip numeric prefixes)

**Impact:** Cannot build multi-platform images. No CI/CD integration possible.

---

### 5. Devcontainer Generator (❌ CRITICAL - NOT IMPLEMENTED)

**What bash does:** `scripts/generate-devcontainer.sh` (200 lines)

**Features:**
1. **Feature references:** `ghcr.io/devcontainers-contrib/features/<name>:1`
2. **Feature options:** Dot notation `java.version=21` → `{"java": {"version": 21}}`
3. **Container env vars:** From `@options:` lines without dots
4. **Service references:** From `@services:` lines (for docker-compose)
5. **VSCode extensions:** Placeholder for customizations

**Example output:**
```json
{
  "name": "solen:quarto-lecture-full",
  "image": "",
  "features": {
    "ghcr.io/devcontainers-contrib/features/python-base:1": {
      "version": "3.11"
    },
    "ghcr.io/devcontainers-contrib/features/quarto:1": {}
  },
  "containerEnv": {
    "QUARTO_VERSION": "1.4.550"
  },
  "customizations": {
    "vscode": { "extensions": [] }
  }
}
```

**What Python CLI needs:**
- Create `solen/generators/devcontainer.py`
- Implement `generate_devcontainer(repo_root: Path, profile: str, output: Path)`
- Parse `@options:` with dot notation (feature.option=value)
- Parse `@services:` lines for docker-compose integration
- JSON formatting with proper escaping

**Impact:** VSCode devcontainer support broken. Users cannot develop in containers.

---

### 6. Feature Metadata Aggregation (⚠️ PARTIAL)

**What bash does:**
```bash
# generate-dockerfile.sh lines 319-333
declare -A __maintainers=()
declare -A __platforms=()
declare -A __provides=()
for f in "${p_feats[@]}"; do
  if [ -f "$FEATURES_DIR/$f/feature.json" ]; then
    # Parse maintainer (object or string)
    while IFS= read -r m; do
      __maintainers["$m"]=1
    done < <(jq -r '.maintainer // empty | if type=="object" then "\(.name) (\(.email))" else . end' ...)

    # Aggregate platforms
    while IFS= read -r plat; do
      __platforms["$plat"]=1
    done < <(jq -r '.platforms[]? // empty' ...)

    # Aggregate provides
    while IFS= read -r prov; do
      __provides["$prov"]=1
    done < <(jq -r '.provides[]? // empty' ...)
  fi
done
```

**What Python CLI does:**
```python
# solen/core/feature.py lines 174-194
def collect_feature_metadata(features_dir: Path, feature_list: list[str]) -> dict[str, list[str]]:
    maintainers: set[str] = set()
    platforms: set[str] = set()
    provides: set[str] = set()

    for feature_id in feature_list:
        metadata = load_feature_metadata(features_dir, feature_id)
        if metadata.maintainer:
            maintainers.add(metadata.maintainer)
        platforms.update(metadata.platforms)
        provides.update(metadata.provides)

    return {
        'maintainers': sorted(maintainers),
        'platforms': sorted(platforms),
        'provides': sorted(provides),
    }
```

**Status:** ✅ Python CLI has this but doesn't emit maintainers/platforms as labels

**Recommendation:** Add optional labels:
```dockerfile
LABEL org.solen.maintainers="<comma-separated>"
LABEL org.solen.platforms="<comma-separated>"
```

---

### 7. Profile Normalization (⚠️ MISSING)

**What bash does:**
```bash
# generate-dockerfile.sh lines 265-283
# Normalize profile names to remove duplicated halves like:
# "java-25-java-25" -> "java-25"
# "quarto-lecture-java-25-quarto-lecture-java-25" -> "quarto-lecture-java-25"
normalized_profiles=()
for p in "${profiles[@]}"; do
  IFS='-' read -r -a toks <<< "$p"
  tlen=${#toks[@]}
  if [ $((tlen % 2)) -eq 0 ] && [ $tlen -gt 0 ]; then
    half=$((tlen/2))
    first_half=("${toks[@]:0:$half}")
    second_half=("${toks[@]:$half:$half}")
    equal=true
    for i in "${!first_half[@]}"; do
      if [ "${first_half[$i]}" != "${second_half[$i]}" ]; then equal=false; break; fi
    done
    if [ "$equal" = true ]; then
      normalized_profiles+=("$(IFS=-; echo "${first_half[*]}")")
      continue
    fi
  fi
  normalized_profiles+=("$p")
done
```

**Status:** ⚠️ Python CLI doesn't detect/fix duplicate profile names

**Impact:** Minor. Could lead to redundant builds if profile matrix generates duplicates.

**Priority:** Medium

---

## Implementation Roadmap

### Phase 1: Git Integration (1-2 hours)
**Priority: CRITICAL**

1. Create `solen/utils/git.py`:
```python
import subprocess
from pathlib import Path

def get_git_sha(repo_root: Path, short: bool = True) -> str:
    """Get current commit SHA."""
    cmd = ['git', 'rev-parse']
    if short:
        cmd.append('--short')
    cmd.append('HEAD')
    try:
        result = subprocess.run(cmd, cwd=repo_root, capture_output=True, text=True, check=True)
        return result.stdout.strip()
    except subprocess.CalledProcessError:
        return 'unknown'

def get_git_branch(repo_root: Path) -> str:
    """Get current branch name (normalized)."""
    try:
        result = subprocess.run(
            ['git', 'rev-parse', '--abbrev-ref', 'HEAD'],
            cwd=repo_root, capture_output=True, text=True, check=True
        )
        branch = result.stdout.strip()
        return branch.replace('/', '-')
    except subprocess.CalledProcessError:
        return 'main'

def get_git_tag(repo_root: Path) -> str | None:
    """Get exact tag at HEAD if exists."""
    try:
        result = subprocess.run(
            ['git', 'describe', '--tags', '--exact-match'],
            cwd=repo_root, capture_output=True, text=True, check=True
        )
        return result.stdout.strip()
    except subprocess.CalledProcessError:
        return None

def get_version_tags(repo_root: Path) -> tuple[str, str]:
    """Get primary and secondary tags based on git state."""
    tag = get_git_tag(repo_root)
    sha = get_git_sha(repo_root, short=True)
    branch = get_git_branch(repo_root)

    if tag:
        return (tag, f'{tag}-{sha}')
    elif branch in ('main', 'master'):
        return ('latest', f'{branch}-{sha}')
    else:
        return (branch, f'{branch}-{sha}')

def is_dirty(repo_root: Path) -> bool:
    """Check if git working tree is dirty."""
    try:
        result = subprocess.run(
            ['git', 'status', '--porcelain'],
            cwd=repo_root, capture_output=True, text=True, check=True
        )
        return bool(result.stdout.strip())
    except subprocess.CalledProcessError:
        return False
```

2. Update `dockerfile.py` to add build args and OCI labels:
```python
from solen.utils.git import get_git_sha, get_version_tags
from datetime import datetime

def emit_dockerfile_header(f: TextIO, repo_root: Path) -> None:
    """Emit Dockerfile header with base image and setup."""
    git_sha = get_git_sha(repo_root, short=False)
    build_date = datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')

    f.write("# Generated Dockerfile\n")
    f.write('ARG VARIANT="ubuntu-24.04"\n')
    f.write('ARG GIT_SHA=unknown\n')
    f.write('ARG BUILD_DATE=unknown\n')
    f.write('ARG GIT_BRANCH=unknown\n')
    f.write('FROM mcr.microsoft.com/devcontainers/base:${VARIANT} AS base\n')
    f.write('LABEL org.solen.vendor="Solen" \\\n')
    f.write(f'      org.opencontainers.image.created="${{BUILD_DATE}}" \\\n')
    f.write(f'      org.opencontainers.image.revision="${{GIT_SHA}}" \\\n')
    f.write('      org.opencontainers.image.source="https://github.com/ebpro/solen"\n')
    # ... rest of header
```

### Phase 2: Docker Bake Generator (2-3 hours)
**Priority: CRITICAL**

Create `solen/generators/bake.py`:
```python
from pathlib import Path
from typing import TextIO
from datetime import datetime

from solen.utils.git import get_version_tags, get_git_sha

def generate_bake(
    repo_root: Path,
    output_path: Path,
    platforms: list[str] | None = None,
    repo: str = "ghcr.io/ebpro",
    image_name: str = "solen"
) -> int:
    """Generate docker-bake.hcl for all profiles."""
    if platforms is None:
        platforms = ["linux/amd64"]

    # Get git-aware tags
    tag1, tag2 = get_version_tags(repo_root)
    git_sha = get_git_sha(repo_root, short=True)
    build_date = datetime.utcnow().strftime('%Y%m%dT%H%M%SZ')
    tags = [tag1, tag2, git_sha, f'build-{build_date}']

    # Collect all profiles
    profiles = collect_all_profiles(repo_root)

    # Write bake file
    with open(output_path, 'w') as f:
        emit_bake_group(f, profiles)

        for profile in profiles:
            emit_bake_target(f, profile, platforms, tags, repo, image_name)

    return len(profiles)

def emit_bake_group(f: TextIO, profiles: list[str]) -> None:
    """Emit group target."""
    f.write('group "all" {\n')
    f.write('  targets = [\n')
    for profile in profiles:
        f.write(f'    "final-{profile}",\n')
    f.write('  ]\n')
    f.write('}\n\n')

def emit_bake_target(
    f: TextIO,
    profile: str,
    platforms: list[str],
    tags: list[str],
    repo: str,
    image_name: str
) -> None:
    """Emit target block for a profile."""
    # Compute profile slug (strip numeric prefixes like "20-00-")
    slug = profile
    import re
    slug = re.sub(r'^[0-9]+(-[0-9]+)*-', '', slug)

    f.write(f'target "final-{profile}" {{\n')
    f.write('  context = "."\n')
    f.write('  dockerfile = "generated/Dockerfile"\n')
    f.write(f'  target = "final-{profile}"\n')
    f.write('  platforms = [\n')
    for platform in platforms:
        f.write(f'    "{platform}",\n')
    f.write('  ]\n')
    f.write('  tags = [\n')
    for tag in tags:
        f.write(f'    "{repo}/{image_name}:{slug}-{tag}",\n')
    f.write('  ]\n')
    f.write('}\n\n')
```

### Phase 3: Devcontainer Generator (2-3 hours)
**Priority: CRITICAL**

Create `solen/generators/devcontainer.py`:
```python
import json
from pathlib import Path
from typing import Any

from solen.core.profile import parse_profile

def generate_devcontainer(repo_root: Path, profile_name: str, output_path: Path) -> None:
    """Generate devcontainer.json for a profile."""
    profile_path = find_profile(profile_name, repo_root)
    profiles_dir = repo_root / 'profiles'
    profile_data = parse_profile(profile_path, profiles_dir)

    # Parse feature options (dot notation: feature.option=value)
    feature_options: dict[str, dict[str, Any]] = {}
    container_env: dict[str, Any] = {}

    for key, value in profile_data.options.items():
        if '.' in key:
            feat, opt = key.split('.', 1)
            if feat not in feature_options:
                feature_options[feat] = {}
            feature_options[feat][opt] = parse_value(value)
        else:
            container_env[key] = parse_value(value)

    # Build features dict
    features: dict[str, dict[str, Any]] = {}
    for feat in profile_data.features:
        feature_ref = f"ghcr.io/devcontainers-contrib/features/{feat}:1"
        features[feature_ref] = feature_options.get(feat, {})

    # Build devcontainer.json
    devcontainer = {
        "name": f"solen:{profile_name}",
        "image": "",
        "features": features,
        "containerEnv": container_env,
        "customizations": {
            "vscode": {"extensions": []}
        }
    }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, 'w') as f:
        json.dump(devcontainer, f, indent=2)

def parse_value(value: str) -> Any:
    """Parse string value to appropriate type."""
    if value.lower() == 'true':
        return True
    elif value.lower() == 'false':
        return False
    elif value.isdigit():
        return int(value)
    else:
        return value
```

### Phase 4: CLI Integration (1 hour)
**Priority: CRITICAL**

Update `solen/cli.py`:
```python
# Add to existing imports
from solen.generators.bake import generate_bake
from solen.generators.devcontainer import generate_devcontainer

# bake command already has stub - update implementation
@generate.command()
@click.option('--output', type=click.Path(path_type=Path),
              default=Path('generated/docker-bake.hcl'), help='Output path')
@click.option('--platforms', default='linux/amd64', help='Target platforms (comma-separated)')
@click.option('--repo', default='ghcr.io/ebpro', help='Container repository')
@click.pass_context
def bake(ctx: click.Context, output: Path, platforms: str, repo: str) -> None:
    """Generate docker-bake.hcl for all profiles."""
    from solen.generators.bake import generate_bake

    repo_root = ctx.obj['repo_root']
    output_path = repo_root / output if not output.is_absolute() else output
    platform_list = [p.strip() for p in platforms.split(',')]

    count = generate_bake(repo_root, output_path, platform_list, repo)
    click.echo(f"✅ Generated docker-bake.hcl with {count} profile(s): {output_path}")

# devcontainer command already has stub - update implementation
@generate.command()
@click.option('--profile', required=True, help='Profile name')
@click.option('--output', type=click.Path(path_type=Path),
              default=Path('generated/devcontainer.json'), help='Output path')
@click.pass_context
def devcontainer(ctx: click.Context, profile: str, output: Path) -> None:
    """Generate devcontainer.json for a profile."""
    from solen.generators.devcontainer import generate_devcontainer

    repo_root = ctx.obj['repo_root']
    output_path = repo_root / output if not output.is_absolute() else output

    generate_devcontainer(repo_root, profile, output_path)
    click.echo(f"✅ Generated devcontainer.json: {output_path}")
```

---

## Testing Strategy

### 1. Git Integration Tests
```bash
# Test git helper functions
.venv/bin/python -c "from solen.utils.git import *; from pathlib import Path; print(get_git_sha(Path('.')))"
.venv/bin/python -c "from solen.utils.git import *; from pathlib import Path; print(get_git_branch(Path('.')))"
.venv/bin/python -c "from solen.utils.git import *; from pathlib import Path; print(get_version_tags(Path('.')))"
```

### 2. Bake Generator Tests
```bash
# Generate bake file
.venv/bin/solen generate bake --platforms linux/amd64,linux/arm64

# Validate HCL syntax
cat generated/docker-bake.hcl

# Test with docker buildx
docker buildx bake --print
```

### 3. Devcontainer Generator Tests
```bash
# Generate devcontainer.json
.venv/bin/solen generate devcontainer --profile quarto-lecture-full

# Validate JSON
jq . generated/devcontainer.json

# Test in VSCode Dev Containers extension
```

### 4. Integration Tests
```bash
# Full workflow
.venv/bin/solen generate dockerfile --profile quarto-lecture-full
.venv/bin/solen generate bake
.venv/bin/solen generate devcontainer --profile quarto-lecture-full

# Build with bake
docker buildx bake final-quarto-lecture-full

# Inspect labels
docker inspect solen:quarto-lecture-full-latest | jq '.[0].Config.Labels'
```

---

## Migration Timeline

**Week 1: Critical Path (Git + Bake + Devcontainer)**
- Day 1-2: Git integration + OCI labels
- Day 3-4: Docker bake generator
- Day 5: Devcontainer generator
- Day 6-7: Testing and validation

**Week 2: Enhancements**
- Profile normalization
- Additional OCI labels (source, url)
- Documentation updates
- Deprecation warnings for bash scripts

**Week 3: Transition**
- Update CI/CD to use Python CLI
- Archive bash scripts
- Final validation

---

## Risk Assessment

| Risk | Impact | Mitigation |
|------|--------|------------|
| Git repo not found | Build fails | Graceful fallback to "unknown" values |
| Invalid git state | Wrong tags | Check `git status` before build |
| HCL syntax errors | Bake fails | Test against docker buildx bake --print |
| JSON syntax errors | VSCode fails | Validate with jq after generation |
| Breaking changes | Users stuck | Maintain bash scripts in parallel for 1 release |

---

## Conclusion

The Python CLI is **functionally incomplete** and **cannot replace bash scripts** without:

1. ✅ **Git integration** (branch, commit, tags, timestamps)
2. ✅ **Docker bake generator** (multi-platform, git-aware tagging)
3. ✅ **Devcontainer generator** (feature options, env vars)
4. ✅ **OCI labels** (created, version, revision)

**Estimated effort:** 10-15 hours of development + testing

**Blocker for:** CI/CD migration, multi-platform builds, devcontainer support

**Recommended action:** Implement Phase 1-3 before deprecating bash scripts.
