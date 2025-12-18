#!/usr/bin/env bash
# Feature: quarto-common
# Create shared directories under /home/<nb_user>/local and install example Quarto templates
set -euo pipefail

# source shared feature helpers when available
if [ -n "${FEATURE_HELPERS_DIR:-}" ] && [ -f "${FEATURE_HELPERS_DIR}/helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "${FEATURE_HELPERS_DIR}/helpers.sh"
elif [ -f "../../../scripts/feature_helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "../../../scripts/feature_helpers.sh"
fi

NB_USER=${NB_USER:-jovyan}
NB_UID=${NB_UID:-1001}
NB_GID=${NB_GID:-1001}
HOME_DIR="/home/${NB_USER}"
CONDA_DIR="${CONDA_DIR:-${HOME_DIR}/miniforge3}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

echo "quarto-common: creating ${HOME_DIR}/local and shared Quarto templates"

# Directories to create
LOCAL_DIR="${HOME_DIR}/local"
DIRS=("${LOCAL_DIR}/work" "${LOCAL_DIR}/repos" "${LOCAL_DIR}/generated" "${LOCAL_DIR}/templates/quarto" "${LOCAL_DIR}/cache")

for d in "${DIRS[@]}"; do
  mkdir -p "${d}" || true
done

# Copy packaged templates into templates dir when present
if [ -d "${SCRIPT_DIR}/files" ]; then
  cp -a "${SCRIPT_DIR}/files/." "${LOCAL_DIR}/templates/quarto/" 2>/dev/null || true
fi

# Ensure ownership and reasonable permissions
chown -R ${NB_UID}:${NB_GID} "${LOCAL_DIR}" || true
chmod -R u+rwX,go+rX,go-w "${LOCAL_DIR}" || true

echo "quarto-common: created ${LOCAL_DIR} with subdirs: work, repos, generated, templates"

exit 0
