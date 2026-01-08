#!/usr/bin/env bash
set -euo pipefail

NB_USER=${NB_USER:-jovyan}
NB_UID=${NB_UID:-1001}
NB_GID=${NB_GID:-1001}
HOME_DIR="/home/${NB_USER}"

echo "quarto-chromium: installing Chromium runtime"

TMP_SCRIPT="/tmp/quarto-chromium-install-${NB_USER}.sh"
cat > "${TMP_SCRIPT}" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$HOME/.local/bin" 2>/dev/null || true
"$HOME/.local/bin/quarto" install chromium --no-prompt || true
BASH

chmod +x "${TMP_SCRIPT}"
su - ${NB_USER} -s /bin/bash -c "${TMP_SCRIPT}" || true
rm -f "${TMP_SCRIPT}"

echo "quarto-chromium: installation complete"
