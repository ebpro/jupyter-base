#!/usr/bin/env bash
set -euo pipefail

echo "profile-k8s: writing features list to /tmp/profile-k8s-features"
cat > /tmp/profile-k8s-features <<'EOF'
base-apt
zsh-config
dev-tools
startup
docker-cli-helper
node
lsp-tools
gh-cli
git-lfs
prompt-helpers
kubernetes-tools
EOF

if [ "${RUN_SUBFEATURES:-false}" = "true" ]; then
  echo "profile-k8s: RUN_SUBFEATURES=true — executing sub-feature install scripts"
  for f in $(cat /tmp/profile-k8s-features); do
    script=.devcontainer/features/${f}/install.sh
    if [ -x "$script" ]; then
      echo "profile-k8s: running $script"
      /bin/bash "$script" || echo "profile-k8s: subfeature $f failed (continuing)"
    else
      echo "profile-k8s: no executable install script for $f, skipping"
    fi
  done
fi

echo "profile-k8s: done"
