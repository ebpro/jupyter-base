#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILES_DIR="$ROOT/profiles"
FEATURES_DIR="$ROOT/.devcontainer/features"

echo "validate-profiles: scanning profiles in $PROFILES_DIR"

missing=0
warn=0

expand_profile(){
  local p="$1"
  local -n out=$2
  declare -A seen
  declare -A in_stack
  _expand(){
    local name="$1"
    if [ -n "${seen[$name]:-}" ]; then return; fi
    if [ -n "${in_stack[$name]:-}" ]; then
      echo "ERROR: cycle detected expanding profile: $name" >&2
      missing=1
      return
    fi
    in_stack[$name]=1
    local f="$PROFILES_DIR/$name"
    if [ ! -f "$f" ]; then
      echo "ERROR: profile not found: $name" >&2
      missing=1
      unset in_stack[$name]
      return
    fi
    # track if a parent was seen to enforce single-parent during expansion
    local parent_seen=0
    while IFS= read -r line || [ -n "$line" ]; do
      line="$(echo "$line" | sed -e 's/^\s*//' -e 's/\s*$//')"
      [ -z "$line" ] && continue
      case "$line" in
        \#*) continue ;;
        @parent:*)
          parent=${line#@parent:}
          if [ "$parent_seen" -ne 0 ]; then
            echo "ERROR: multiple @parent: directives in profile '$name'" >&2
            missing=1
          else
            parent_seen=1
            _expand "$parent"
          fi
          ;;
        @profile:*)
          sub=${line#@profile:}
          _expand "$sub"
          ;;
        *) out+=("$line") ;;
      esac
    done < "$f"
    seen[$name]=1
    unset in_stack[$name]
  }
  _expand "$p"
}

for pf in "$PROFILES_DIR"/*; do
  name=$(basename "$pf")
  [ "$name" = "README.md" ] && continue
  echo "- Checking profile: $name"
  # enforce filename prefix format when a numeric prefix is used
  if printf '%s' "$name" | grep -qE '^[0-9]{2}-'; then
    if ! printf '%s' "$name" | grep -qE '^[0-9]{2}(-[0-9]{2})?-[a-z0-9]'; then
      echo "  ERROR: profile filename '$name' does not follow numeric-prefix naming (expected NN-... or NN-NN-... )" >&2
      missing=1
      continue
    fi
  fi
  # Quick static check: ensure at most one @parent: directive
  # use grep -c to return a numeric count and sanitize it
  parent_count=$(grep -c -E '^[[:space:]]*@parent:' "$PROFILES_DIR/$name" 2>/dev/null || true)
  # ensure parent_count is numeric (fallback to 0)
  if ! printf '%d' "$parent_count" >/dev/null 2>&1; then
    parent_count=0
  fi
  if [ "$parent_count" -gt 1 ]; then
    echo "  ERROR: profile '$name' has multiple @parent: directives" >&2
    missing=1
    continue
  fi

  # If filename indicates a child (NN-NN-...), require a @parent: directive
  # Exception: allow NN-NN-base files to be parentless (explicit base profiles)
  if printf '%s' "$name" | grep -qE '^[0-9]{2}-[0-9]{2}-'; then
    if ! printf '%s' "$name" | grep -qE '-base$'; then
      if [ "$parent_count" -eq 0 ]; then
        echo "  ERROR: profile '$name' appears to be a child (numeric prefix) but has no @parent: directive" >&2
        missing=1
        continue
      fi
    fi
  fi

  resolved=()
  expand_profile "$name" resolved
  if [ ${#resolved[@]} -eq 0 ]; then
    echo "  (no features found)"
    continue
  fi
  # If a parent is declared, expand parent-only features to detect duplicates
  parent_provided=()
  if [ "$parent_count" -eq 1 ]; then
    parent_token=$(grep -E '^[[:space:]]*@parent:' "$PROFILES_DIR/$name" | sed -E 's/^[[:space:]]*@parent://;s/[[:space:]]+//g' | head -n1)
    # find matching profile file for the token (exact or suffix match)
    matched=""
    for f in "$PROFILES_DIR"/*; do
      bn=$(basename "$f")
      if [ "$bn" = "$parent_token" ] || [ "${bn##*-}" = "$parent_token" ]; then
        matched="$bn"
        break
      fi
    done
    if [ -n "$matched" ]; then
      parent_provided=()
      expand_profile "$matched" parent_provided
    else
      echo "  ERROR: parent profile token '$parent_token' referenced from '$name' not found" >&2
      missing=1
      continue
    fi
  fi
  # check features exist and have install.sh or feature.json
  idx=0
  saw_codeserver=0
  for f in "${resolved[@]}"; do
    idx=$((idx+1))
    if [ ! -d "$FEATURES_DIR/$f" ]; then
      echo "  ERROR: feature '$f' referenced in profile '$name' not found at $FEATURES_DIR/$f" >&2
      missing=1
      continue
    fi
    if [ ! -f "$FEATURES_DIR/$f/install.sh" ] && [ ! -f "$FEATURES_DIR/$f/feature.json" ]; then
      echo "  WARN: feature '$f' has no install.sh or feature.json" >&2
      warn=1
    fi
    if [ "$f" = "code-server" ]; then
      saw_codeserver=1
    fi
    if [ "$f" = "codeserver-extensions" ] && [ $saw_codeserver -ne 1 ]; then
      echo "  WARN: 'codeserver-extensions' appears before 'code-server' in expanded profile '$name' (extensions need runtime present)" >&2
      warn=1
    fi
  done

  # Detect duplicates: features explicitly listed in this profile that are provided by parent chain
  if [ ${#parent_provided[@]} -ne 0 ]; then
    # read explicit features from this file (non-directive, non-comment)
    explicit=()
    while IFS= read -r line || [ -n "$line" ]; do
      line="$(echo "$line" | sed -e 's/^\s*//' -e 's/\s*$//')"
      [ -z "$line" ] && continue
      case "$line" in
        \#*) continue ;;
        @*) continue ;;
        *) explicit+=("$line") ;;
      esac
    done < "$PROFILES_DIR/$name"
    for ef in "${explicit[@]}"; do
      for pfv in "${parent_provided[@]}"; do
        if [ "$ef" = "$pfv" ]; then
          echo "  ERROR: feature '$ef' in profile '$name' is already provided by @parent chain" >&2
          missing=1
        fi
      done
    done
  fi
done

if [ $missing -ne 0 ]; then
  echo "validate-profiles: FAILED (missing features)" >&2
  exit 2
fi

if [ $warn -ne 0 ]; then
  echo "validate-profiles: completed with warnings" >&2
  exit 1
fi

echo "validate-profiles: OK"
exit 0
