#!/usr/bin/env bash
set -euo pipefail

# --- Environment Check ---
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  echo "Error: this script requires Bash 4 or newer." >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILES_DIR="$ROOT/profiles"
FEATURES_DIR="$ROOT/.devcontainer/features"
OUT="Dockerfile.generated"

# --- Helpers ---
docker_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

expand_profile(){
  local pname="$1"
  local out_feat_array="$2"
  local out_env_array="$3"
  if [ -n "${VISITED[$pname]:-}" ]; then return; fi
  VISITED[$pname]=1
  local f="$PROFILES_DIR/$pname"
  [ ! -f "$f" ] && { echo "Profile not found: $pname" >&2; exit 3; }

  while IFS= read -r line || [ -n "$line" ]; do
    local_trim="$(echo "$line" | xargs 2>/dev/null || echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$local_trim" ] && continue
    case "$local_trim" in
      \#*) continue ;;
      @parent:*|@profile:*)
        expand_profile "$(echo "${local_trim#*:}" | xargs)" "$out_feat_array" "$out_env_array"
        ;;
      @options:*)
        IFS=';' read -ra pairs <<< "${local_trim#@options:}"
        for pair in "${pairs[@]}"; do
          pair="$(echo "$pair" | xargs)"
          [ -z "$pair" ] && continue
          local key="${pair%%=*}"
          local val="${pair#*=}"
          if [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
             eval "$out_env_array+=(\"$key=$(echo "$val" | xargs)\")"
          fi
        done
        ;;
      *) eval "$out_feat_array+=(\"$local_trim\")" ;;
    esac
  done < "$f"
}

emit_run_features() {
  local -n feats=$1
  [ ${#feats[@]} -eq 0 ] && return
  # Emit per-feature bind/cache mounts one-per-line to avoid embedding literal
  # backslash-newline sequences in the generated Dockerfile.
  echo "RUN \\" >> "$OUT"
  for feat in "${feats[@]}"; do
    echo "  --mount=type=bind,source=.devcontainer/features/${feat},target=/tmp/features/${feat} \\" >> "$OUT"
    echo "  --mount=type=cache,target=/tmp/.cache/${feat} \\" >> "$OUT"
  done
  echo "  --mount=type=bind,source=Artefacts,target=/tmp/Artefacts \\" >> "$OUT"

  # Build a quoted array literal for the in-container loop so feature names are safe
  local quoted_feats=()
  for f in "${feats[@]}"; do quoted_feats+=("\"$f\""); done
  local feats_array
  feats_array=$(IFS=' '; printf '%s ' "${quoted_feats[@]}")

  echo "  bash -eux -o pipefail -c 'feats=(${feats_array}); for f in \"\${feats[@]}\"; do \\" >> "$OUT"
  echo "    if [ -d \"/tmp/features/\$f\" ]; then \\" >> "$OUT"
  echo "      chmod +x /tmp/features/\$f/install.sh 2>/dev/null || true; \\" >> "$OUT"
  echo "      [ -f /tmp/features/\$f/install.sh ] && { set +u; bash /tmp/features/\$f/install.sh; set -u; }; \\" >> "$OUT"
  echo "    fi; \\" >> "$OUT"
  echo "  done; apt-get clean; rm -rf /var/lib/apt/lists/*'" >> "$OUT"
}

# --- Initialization ---
cat > "$OUT" <<EOF
# Generated Dockerfile
ARG VARIANT="ubuntu-24.04"
FROM mcr.microsoft.com/devcontainers/base:\${VARIANT} AS base
LABEL org.solen.vendor="Solen"
ARG NB_USER=jovyan
ARG NB_UID=1001
ARG NB_GID=1001
ENV HOME=/home/jovyan
WORKDIR /home/jovyan

COPY shared/_lib/helpers.sh /opt/solen/_lib/helpers.sh
COPY Artefacts /opt/solen/Artefacts
ENV FEATURE_HELPERS_DIR=/opt/solen/_lib ARTIFACTS_DIR=/opt/solen/Artefacts
RUN mkdir -p /opt/.features /scripts && \\
    printf "source /opt/solen/_lib/helpers.sh || true" > /scripts/feature_helpers.sh
EOF

# --- Argument Parsing ---
PROFILE=""
ALL=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --profile) PROFILE="$2"; shift 2 ;;
    --all-profiles) ALL=true; shift ;;
    --out) OUT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

declare -a generated_stages=()

if [ "$ALL" = true ]; then
  profiles=()
  for f in "$PROFILES_DIR"/*; do
    name=$(basename "$f")
    [[ "$name" == "README.md" || "$name" == "base" ]] && continue
    profiles+=("$name")
  done
  IFS=$'\n' profiles=($(sort -V <<<"${profiles[*]}"))
  unset IFS

  declare -A full_feat_lists
  for p in "${profiles[@]}"; do
    unset VISITED; declare -A VISITED
    declare -a p_feats=()
    declare -a p_envs=()
    expand_profile "$p" p_feats p_envs

    parent=$(grep "@parent:" "$PROFILES_DIR/$p" | head -1 | cut -d: -f2 | xargs || echo "base")
    parent_stage="base"
    [[ "$parent" != "base" ]] && parent_stage="profile-$parent"

    declare -a unique_feats=()
    for f in "${p_feats[@]}"; do
      if [[ "$parent" == "base" ]] || [[ ! " ${full_feat_lists[$parent]} " =~ " $f " ]]; then
        unique_feats+=("$f")
      fi
    done
    full_feat_lists[$p]="${p_feats[*]}"

    echo -e "\n# --- Profile: $p ---" >> "$OUT"
    echo "FROM $parent_stage AS profile-$p" >> "$OUT"

    # Collect and Join Metadata
    declare -A __maintainers=()
    declare -A __platforms=()
    declare -A __provides=()
    for f in "${p_feats[@]}"; do
      if [ -f "$FEATURES_DIR/$f/feature.json" ]; then
        while IFS= read -r m; do [ -n "$m" ] && __maintainers["$m"]=1; done < <(jq -r '.maintainer // empty | if type=="object" then "\(.name) (\(.email))" else . end' "$FEATURES_DIR/$f/feature.json" 2>/dev/null || true)
        while IFS= read -r plat; do [ -n "$plat" ] && __platforms["$plat"]=1; done < <(jq -r '.platforms[]? // empty' "$FEATURES_DIR/$f/feature.json" 2>/dev/null || true)
        while IFS= read -r prov; do [ -n "$prov" ] && __provides["$prov"]=1; done < <(jq -r '.provides[]? // empty' "$FEATURES_DIR/$f/feature.json" 2>/dev/null || true)
      fi
    done

    join_sorted() {
      local -n arr=$1
      [ ${#arr[@]} -eq 0 ] && return
      printf '%s\n' "${!arr[@]}" | sort | tr '\n' ',' | sed 's/,$//'
    }

    mnt=$(join_sorted __maintainers)
    plats=$(join_sorted __platforms)
    provs=$(join_sorted __provides)

    # Simplified Label Output
    cat <<EOF >> "$OUT"
LABEL org.solen.profile="$p" \\
      org.solen.features.added="${unique_feats[*]:-none}" \\
      org.solen.features.provides="$provs"
EOF

    # Output ENVs
    for env in "${p_envs[@]}"; do echo "ENV ${env%%=*}=\"$(docker_escape "${env#*=}")\"" >> "$OUT"; done

    # Feature Option Defaults
    declare -A __opt_defaults=()
    for feat in "${p_feats[@]}"; do
      if [ -f "$FEATURES_DIR/$feat/feature.json" ]; then
        while IFS= read -r line; do
          [ -z "$line" ] && continue
          __opt_defaults["${line%%=*}"]="${line#*=}"
        done < <(jq -r '.options // {} | to_entries[] | "\(.key)=\(.value.default // \"\")"' "$FEATURES_DIR/$feat/feature.json" 2>/dev/null || true)
      fi
    done

    declare -A __profile_env_keys=()
    for env in "${p_envs[@]}"; do __profile_env_keys["${env%%=*}"]=1; done
    for k in "${!__opt_defaults[@]}"; do
      if [ -z "${__profile_env_keys[$k]:-}" ]; then
        echo "ENV $k=\"$(docker_escape "${__opt_defaults[$k]}")\"" >> "$OUT"
      fi
    done

    emit_run_features unique_feats
    echo "FROM profile-$p AS final-$p" >> "$OUT"
    generated_stages+=("$p")
  done
fi
