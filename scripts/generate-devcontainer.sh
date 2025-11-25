#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILES_DIR="$ROOT/profiles"
FEATURES_DIR="$ROOT/.devcontainer/features"

usage(){
  cat <<EOF
Usage: $(basename "$0") --profile <name> [--out devcontainer.json] [--dry-run]

Generates a simple devcontainer.json that lists selected features.
EOF
}

PROFILE=""
OUT="devcontainer.generated.json"
DRY=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --profile) PROFILE="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --dry-run) DRY=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

if [ -z "$PROFILE" ]; then
  echo "--profile is required" >&2; usage; exit 2
fi

declare -a RESOLVED
declare -A VISITED

expand_profile(){
  local p="$1"
  if [ -n "${VISITED[$p]:-}" ]; then
    return
  fi
  VISITED[$p]=1
  local f="$PROFILES_DIR/$p"
  if [ ! -f "$f" ]; then
    echo "Profile not found: $p" >&2; exit 3
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line="$(echo "$line" | sed -e 's/^\s*//' -e 's/\s*$//')"
    [ -z "$line" ] && continue
    case "$line" in
      \#*) continue ;;
      @profile:*)
        sub=${line#@profile:}
        expand_profile "$sub"
        ;;
      *)
        RESOLVED+=("$line")
        ;;
    esac
  done < "$f"
}

expand_profile "$PROFILE"

if [ "$DRY" = true ]; then
  echo "Resolved features for profile '$PROFILE':"
  for f in "${RESOLVED[@]}"; do echo " - $f"; done
  exit 0
fi

# Build minimal devcontainer.json
cat > "$OUT" <<JSON
{
  "name": "solen:$PROFILE",
  "image": "",
  "features": {
JSON

first=true
for feat in "${RESOLVED[@]}"; do
  if [ "$first" = true ]; then first=false; else echo "," >> "$OUT"; fi
  echo "    \"ghcr.io/devcontainers-contrib/features/$feat:1\": {}" >> "$OUT"
done

cat >> "$OUT" <<JSON

  },
  "customizations": {
    "vscode": { "extensions": [] }
  }
}
JSON

echo "devcontainer.json generated to $OUT"
exit 0
