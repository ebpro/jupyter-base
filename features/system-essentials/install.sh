#!/usr/bin/env bash
# Auto-inserted by scripts/inject_prebaked_helpers.sh
# Source shared feature helpers (prebaked into image) or fall back to repository helper
if [ -n "${FEATURE_HELPERS_DIR:-}" ] && [ -f "${FEATURE_HELPERS_DIR}/helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "${FEATURE_HELPERS_DIR}/helpers.sh"
elif [ -f "../../../scripts/lib/features.sh" ]; then
  # shellcheck disable=SC1091
  source "../../../scripts/lib/features.sh"
fi
set -euo pipefail

# Ensure per-user local/cache dirs exist (use helper when available, fallback otherwise)
if command -v fh_ensure_user_dirs >/dev/null 2>&1; then
  fh_ensure_user_dirs "${NB_USER:-jovyan}" "${NB_UID:-1001}" "${NB_GID:-1001}" || true
else
  HOME_DIR=${HOME_DIR:-/home/${NB_USER:-jovyan}}
  mkdir -p "${HOME_DIR}/.local/bin" "${HOME_DIR}/.cache" "${HOME_DIR}/.cache/pip" >/dev/null 2>&1 || true
  chown -R ${NB_UID:-1001}:${NB_GID:-1001} "${HOME_DIR}/.local" "${HOME_DIR}/.cache" >/dev/null 2>&1 || true
fi

APT_LIST="/tmp/inputs/apt-packages/base"
if [ ! -f "${APT_LIST}" ] && [ -f /tmp/inputs/apt-packages_base ]; then
  APT_LIST="/tmp/inputs/apt-packages_base"
fi

echo "system-essentials: installing packages listed in ${APT_LIST} (if present)"
if [ -f "${APT_LIST}" ]; then
  PKGS=$(grep -v -e "^#" -e "^$" "${APT_LIST}" | tr '\n' ' ' || true)
  PKGS=$(echo "$PKGS" | xargs || true)
  if [ -n "$PKGS" ]; then
    # Use helper apt_install where available for consistent, non-interactive installs
    if command -v apt_install >/dev/null 2>&1; then
      apt_install $PKGS || true
    else
      apt-get update
      apt-get install -y --no-install-recommends $PKGS || true
      rm -rf /var/lib/apt/lists/* || true
    fi
  fi
else
  echo "system-essentials: ${APT_LIST} not present; skipping"
fi

# --- begin required-package assertion ---
# Why the install above stays tolerant (`|| true`) and this check exists:
#
#   The apt install is deliberately ONE transaction over the *union* list
#   ${APT_LIST}, unchanged, so that layer bytes and dependency resolution stay
#   identical for every profile. A single unavailable package aborts that whole
#   transaction (the partial-transaction hazard), so making the install itself
#   fatal would let one arch-unavailable OPTIONAL package break every profile.
#
#   But `apt_install` retries 3x and `return 1` (scripts/lib/features.sh), and
#   the caller discards it -- so before this assertion a missing REQUIRED
#   package disappeared from every published image while CI stayed green.
#   The tolerance is therefore bounded by a post-condition: everything named in
#   ${APT_LIST}.required must actually be installed, or the build fails here.
#
#   Remedy for a real arch gap: DEMOTE the package (move its name from
#   base.required to base.optional). Never mask this check with `|| true`.
#
# In-image only (Linux + dpkg), and bash 3.2 compatible -- no `mapfile`, no
# `${VAR,,}` -- because host harnesses source these scripts.
REQUIRED_LIST="${APT_LIST}.required"
OPTIONAL_LIST="${APT_LIST}.optional"
if [ "$(uname -s 2>/dev/null || true)" = "Linux" ] && command -v dpkg-query >/dev/null 2>&1; then
  if [ ! -f "${REQUIRED_LIST}" ]; then
    echo "system-essentials: WARNING ${REQUIRED_LIST} not found; required packages are NOT being asserted and a missing one would pass silently" >&2
  else
    MISSING=""
    while IFS= read -r pkg; do
      case "${pkg}" in '' | '#'*) continue ;; esac
      for tok in ${pkg}; do
        if ! dpkg-query -W -f='${Status}' "${tok}" 2>/dev/null | grep -q 'install ok installed'; then
          MISSING="${MISSING} ${tok}"
        fi
      done
    done < "${REQUIRED_LIST}"
    if [ -n "${MISSING}" ]; then
      echo "system-essentials: FAILED - required apt package(s) not installed after the apt transaction:${MISSING}" >&2
      echo "system-essentials:   required list: ${REQUIRED_LIST}" >&2
      echo "system-essentials:   union list   : ${APT_LIST} (packages attempted: $(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "${APT_LIST}" | tr '\n' ' '))" >&2
      echo "system-essentials:   optional list : ${OPTIONAL_LIST}" >&2
      echo "system-essentials: The union list is installed as ONE apt transaction, so any single unavailable package -- including an optional one -- makes every required package above vanish together; that is why the install is tolerant and this assertion is not." >&2
      echo "system-essentials: Remedy: if a package above is genuinely unavailable on this architecture, demote it by moving its name from ${REQUIRED_LIST} to ${OPTIONAL_LIST}; otherwise fix ${APT_LIST} or the apt source. Do not silence this check." >&2
      exit 1
    fi
    echo "system-essentials: required packages verified present"
  fi
fi
# --- end required-package assertion ---

echo "system-essentials: done"
