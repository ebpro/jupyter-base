#!/usr/bin/env bash
# Auto-inserted by scripts/inject_prebaked_helpers.sh
# Source shared feature helpers (prebaked into image) or fall back to repository helper
if [ -n "${FEATURE_HELPERS_DIR:-}" ] && [ -f "${FEATURE_HELPERS_DIR}/helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "${FEATURE_HELPERS_DIR}/helpers.sh"
elif [ -f "../../../scripts/feature_helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "../../../scripts/feature_helpers.sh"
fi
set -euo pipefail

# Install the Poppler PDF command-line tools (pdftotext, pdftoppm, pdfinfo, ...).
#
# `poppler-data` is deliberately NOT listed: the helper installs with
# --no-install-recommends, which keeps that ~40 MB of CJK / unusual-encoding
# glyph tables out of the image. See features/poppler-utils/README.md.
#
# No version pin and no checksum: this is a plain apt package, so it follows
# the same shape as features/redis-client (checksums.json covers artefacts/
# downloads only). Install failures must be loud, so there is no `|| true`.
echo "poppler-utils: installing poppler-utils"
if command -v apt_install >/dev/null 2>&1; then
  apt_install poppler-utils
else
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends poppler-utils
fi
rm -rf /var/lib/apt/lists/* || true

echo "poppler-utils: done"
