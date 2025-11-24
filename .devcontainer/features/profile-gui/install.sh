#!/usr/bin/env bash
set -euo pipefail

echo "profile-gui: writing features list to /tmp/profile-gui-features"
cat > /tmp/profile-gui-features <<'EOF'
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
codeserver-extensions
jetbrains-gateway
# Note: GUI extras (X11, browsers) should be added to a 'gui' feature if needed
EOF

if [ "${RUN_SUBFEATURES:-false}" = "true" ]; then
  echo "profile-gui: RUN_SUBFEATURES=true — executing sub-feature install scripts"
  for f in $(cat /tmp/profile-gui-features); do
    # skip comment lines
    case "$f" in \#*) continue ;; esac
    script=.devcontainer/features/${f}/install.sh
    if [ -x "$script" ]; then
      echo "profile-gui: running $script"
      /bin/bash "$script" || echo "profile-gui: subfeature $f failed (continuing)"
    else
      echo "profile-gui: no executable install script for $f, skipping"
    fi
  done
fi

echo "profile-gui: done"
