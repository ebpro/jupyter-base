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
declare -A FEATURE_OPTS
declare -a CONTAINER_ENV

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
    line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/\r//g')"
    [ -z "$line" ] && continue
    case "$line" in
      \#*) continue ;;
      @profile:*)
        sub=${line#@profile:}
        expand_profile "$sub"
        ;;
      @parent:*)
        sub=${line#@parent:}
        expand_profile "$sub"
        ;;
      @options:*)
        opts=${line#@options:}
        # split on ';' and parse key=value pairs
        IFS=';' read -ra pairs <<< "$opts"
        for pair in "${pairs[@]}"; do
          pair="$(echo "$pair" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
          [ -z "$pair" ] && continue
            key=${pair%%=*}
            val=${pair#*=}
            # robust trim for key/val
            key="$(echo "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/\r//g')"
            val="$(echo "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/\r//g')"
          # if key contains a dot, treat as feature.option
          if [[ "$key" == *.* ]]; then
            feat=${key%%.*}
            opt=${key#*.}
            # accumulate JSON-like string for the feature
            # prefer to merge multiple options
              # format val: booleans/numbers unquoted, else quote
              if [[ "$val" == "true" || "$val" == "false" || "$val" =~ ^[0-9]+$ ]]; then
                formatted=$val
              else
                esc=$(printf '%s' "$val" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
                formatted="\"$esc\""
              fi
              prev=${FEATURE_OPTS[$feat]:-}
              if [ -z "$prev" ]; then
                FEATURE_OPTS[$feat]="\"$opt\":$formatted"
              else
                FEATURE_OPTS[$feat]="$prev, \"$opt\":$formatted"
              fi
          else
            # treat as container env var
              CONTAINER_ENV+=("$key=$val")
          fi
        done
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
  # trim and skip directives
  feat_trimmed="$(echo "$feat" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/\r//g')"
  # skip lines that look like directives
  case "$feat_trimmed" in
    @*) continue ;;
    \#*) continue ;;
  esac
  # validate feature name (simple check)
  if ! [[ "$feat_trimmed" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    continue
  fi
  # write comma if not first
  if [ "$first" = true ]; then first=false; else echo "," >> "$OUT"; fi
  # build options JSON if present
  optjson="{}"
  if [ -n "${FEATURE_OPTS[$feat_trimmed]:-}" ]; then
    optjson="{ ${FEATURE_OPTS[$feat_trimmed]} }"
  fi
  echo "    \"ghcr.io/devcontainers-contrib/features/$feat_trimmed:1\": $optjson" >> "$OUT"
done

cat >> "$OUT" <<JSON

  },
  "containerEnv": {
JSON

firstenv=true
for env in "${CONTAINER_ENV[@]:-}"; do
  key=${env%%=*}
  val=${env#*=}
  # emit comma if not first
  if [ "$firstenv" = true ]; then firstenv=false; else echo "," >> "$OUT"; fi
  # determine if val is boolean or number
  if [[ "$val" == "true" || "$val" == "false" || "$val" =~ ^[0-9]+$ ]]; then
    echo "    \"$key\": $val" >> "$OUT"
  else
    # escape backslashes and double quotes
    esc=$(printf '%s' "$val" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    echo "    \"$key\": \"$esc\"" >> "$OUT"
  fi
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
