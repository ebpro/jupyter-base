#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILES_DIR="$ROOT/profiles"
OUT="docker-bake.generated.hcl"

echo "generate-bake: scanning profiles in $PROFILES_DIR"

targets=()
for f in "$PROFILES_DIR"/*; do
  name=$(basename "$f")
  [ "$name" = "README.md" ] && continue
  targets+=("$name")
done
# Sort targets using version sort so numeric prefixes order naturally
if [ ${#targets[@]} -gt 0 ]; then
  IFS=$'\n' read -r -d '' -a targets < <(printf "%s\n" "${targets[@]}" | sort -V && printf '\0')
fi

# BAKE_PLATFORMS should be a comma-separated list like linux/amd64,linux/arm64
# BAKE_ARCHS should be comma-separated arch tokens like amd64,arm64
BAKE_PLATFORMS=${BAKE_PLATFORMS:-"linux/amd64"}
BAKE_ARCHS=${BAKE_ARCHS:-"amd64"}

# Defaults for image tagging and repository. These can be overridden by
# exporting environment variables when invoking the script (e.g. from
# `build.sh` or CI). Default to GitHub Container Registry under the org
# `ebpro` and the `solen` image name.
REPO=${REPO:-ghcr.io/ebpro}
IMAGE_NAME=${IMAGE_NAME:-solen}
TAG1=${TAG1:-latest}
TAG2=${TAG2:-latest-sha}

IFS=',' read -r -a PLAT_ARR <<< "$BAKE_PLATFORMS"
IFS=',' read -r -a ARCH_ARR <<< "$BAKE_ARCHS"

# Write the group listing all final-<profile> targets
cat > "$OUT" <<HCL
group "all" {
  targets = [
HCL

for t in "${targets[@]}"; do
  echo "    \"final-$t\"," >> "$OUT"
done

cat >> "$OUT" <<HCL
  ]
}

HCL

# Emit one HCL target block per profile
for t in "${targets[@]}"; do
  cat >> "$OUT" <<HCL
target "final-$t" {
  context = "."
  dockerfile = "Dockerfile.generated"
  target = "final-$t"
  platforms = [
HCL
  for p in "${PLAT_ARR[@]}"; do
    echo "    \"$p\"," >> "$OUT"
  done
  cat >> "$OUT" <<HCL
  ]
  tags = [
    "${REPO}/${IMAGE_NAME}:${TAG1}",
    "${REPO}/${IMAGE_NAME}:${TAG2}",
  ]
}

HCL
done

echo "Generated bake file: $OUT"
echo "Bake platforms: $BAKE_PLATFORMS"
echo "Bake arch tags: $BAKE_ARCHS"
# end
exit 0
