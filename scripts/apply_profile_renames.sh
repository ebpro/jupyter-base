#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

echo "Applying hierarchical profile renames and updating references..."

# Rename files (allow already-moved)
mv_if_exists(){
  src="$1"; dst="$2"
  if [ -f "$src" ]; then
    git mv "$src" "$dst"
    echo "mv $src -> $dst"
  else
    echo "skip mv: $src (not present)"
  fi
}

mv_if_exists profiles/10-minimal profiles/00-01-minimal || true
mv_if_exists profiles/20-dev profiles/10-00-dev || true
mv_if_exists profiles/21-containers-tools profiles/10-01-containers-tools || true
mv_if_exists profiles/50-podman profiles/10-02-podman || true
mv_if_exists profiles/30-data-science profiles/20-00-data-science || true
mv_if_exists profiles/31-quarto-lecture profiles/20-01-quarto-lecture || true
mv_if_exists profiles/32-quarto-lecture-full profiles/20-02-quarto-lecture-full || true
mv_if_exists profiles/33-teaching-interactive profiles/20-03-teaching-interactive || true
mv_if_exists profiles/40-k8s-dev profiles/30-00-k8s-dev || true
mv_if_exists profiles/41-k8s-sim profiles/30-01-k8s-sim || true
mv_if_exists profiles/60-codeserver profiles/40-00-codeserver || true
mv_if_exists profiles/61-jetbrains-gateway profiles/40-01-jetbrains-gateway || true
mv_if_exists profiles/90-full profiles/50-00-full || true

# Update @profile/@parent references in files under profiles/
# We'll do safe replacements using perl; create a backup suffix to allow inspection if needed
perl -0777 -pi.bak -e 's/(?<=@(?:profile|parent):)(?:10-minimal|minimal)/00-01-minimal/g' profiles/* || true
perl -0777 -pi.bak -e 's/(?<=@(?:profile|parent):)(?:20-dev|dev)/10-00-dev/g' profiles/* || true
perl -0777 -pi.bak -e 's/(?<=@(?:profile|parent):)(?:21-containers-tools|containers-tools)/10-01-containers-tools/g' profiles/* || true
perl -0777 -pi.bak -e 's/(?<=@(?:profile|parent):)(?:50-podman|podman)/10-02-podman/g' profiles/* || true
perl -0777 -pi.bak -e 's/(?<=@(?:profile|parent):)(?:30-data-science|data-science)/20-00-data-science/g' profiles/* || true
perl -0777 -pi.bak -e 's/(?<=@(?:profile|parent):)(?:31-quarto-lecture|quarto-lecture)/20-01-quarto-lecture/g' profiles/* || true
perl -0777 -pi.bak -e 's/(?<=@(?:profile|parent):)(?:32-quarto-lecture-full|quarto-lecture-full)/20-02-quarto-lecture-full/g' profiles/* || true
perl -0777 -pi.bak -e 's/(?<=@(?:profile|parent):)(?:33-teaching-interactive|teaching-interactive)/20-03-teaching-interactive/g' profiles/* || true
perl -0777 -pi.bak -e 's/(?<=@(?:profile|parent):)(?:40-k8s-dev|k8s-dev)/30-00-k8s-dev/g' profiles/* || true
perl -0777 -pi.bak -e 's/(?<=@(?:profile|parent):)(?:41-k8s-sim|k8s-sim)/30-01-k8s-sim/g' profiles/* || true
perl -0777 -pi.bak -e 's/(?<=@(?:profile|parent):)(?:60-codeserver|codeserver)/40-00-codeserver/g' profiles/* || true
perl -0777 -pi.bak -e 's/(?<=@(?:profile|parent):)(?:61-jetbrains-gateway|jetbrains-gateway)/40-01-jetbrains-gateway/g' profiles/* || true
perl -0777 -pi.bak -e 's/(?<=@(?:profile|parent):)(?:90-full|full)/50-00-full/g' profiles/* || true

# Remove perl backup files
rm -f profiles/*.bak || true

# Run validator and regenerate artifacts
echo "Running profile validator..."
./scripts/validate-profiles.sh

echo "Generating Dockerfile and bake HCL..."
bash ./scripts/generate-dockerfile.sh --all-profiles --out Dockerfile.generated
BAKE_PLATFORMS=linux/amd64,linux/arm64 BAKE_ARCHS=amd64,arm64 REPO=ebpro IMAGE_NAME=solen TAG1=latest TAG2=latest-sha ./scripts/generate-bake.sh

# Commit changes
git add -A
if git commit -m "chore(profiles): apply hierarchical numeric prefix renames and update references"; then
  echo "Committed rename changes"
else
  echo "No commit needed or commit failed (maybe nothing to commit)"
fi

echo "Done"
