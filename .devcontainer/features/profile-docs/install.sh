#!/usr/bin/env bash
set -euo pipefail

echo "profile-docs: writing features list to /tmp/profile-docs-features"
cat > /tmp/profile-docs-features <<'EOF'
_lib/checksum-verify
_lib/toolcache
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
quarto
texlive
pip-requirements
jupyter-kernels
EOF

if [ "${RUN_SUBFEATURES:-false}" = "true" ]; then
  echo "profile-docs: RUN_SUBFEATURES=true — executing sub-feature install scripts"
  for f in $(cat /tmp/profile-docs-features); do
    script=.devcontainer/features/${f}/install.sh
    if [ -x "$script" ]; then
      echo "profile-docs: running $script"
      /bin/bash "$script" || echo "profile-docs: subfeature $f failed (continuing)"
    else
      echo "profile-docs: no executable install script for $f, skipping"
    fi
  done
fi

echo "profile-docs: done"
