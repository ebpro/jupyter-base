#!/usr/bin/env bash
set -euo pipefail

# --- Environment Check ---
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  echo "Error: this script requires Bash 4 or newer." >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILES_DIR="$ROOT/profiles"
FEATURES_DIR="$ROOT/features"
OUT="generated/Dockerfile"

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
  # Support generated profiles in generated/profiles as well as repo profiles
  if [ -f "$f" ]; then
    :
  elif [ -f "$ROOT/generated/profiles/$pname" ]; then
    f="$ROOT/generated/profiles/$pname"
  else
    echo "Profile not found: $pname" >&2
    echo "Available profiles:" >&2
    # List profiles from both repo and generated folder
    for q in "$PROFILES_DIR"/* "$ROOT/generated/profiles"/*; do
      [ -f "$q" ] || continue
      echo "  - $(basename "$q")" >&2
    done

    # Try to suggest likely matches (case-insensitive substring match)
    # Strip any leading numeric prefixes like "11-00-" to get a canonical token
    stripped=$(echo "$pname" | sed -E 's/^[0-9]+(-[0-9]+)*-//')
    lowp=$(echo "$stripped" | tr '[:upper:]' '[:lower:]')
    echo "Possible matches:" >&2
    suggested=false
    for q in "$PROFILES_DIR"/* "$ROOT/generated/profiles"/*; do
      [ -f "$q" ] || continue
      name=$(basename "$q")
      lown=$(echo "$name" | tr '[:upper:]' '[:lower:]')
      # Match if the whole stripped token appears, or any hyphen-separated token appears
      match=false
      if [[ "$lown" == *"$lowp"* ]]; then
        match=true
      else
        IFS='-' read -ra toks <<< "$lowp"
        for t in "${toks[@]}"; do
          [ -z "$t" ] && continue
          if [[ "$lown" == *"$t"* ]]; then match=true; break; fi
        done
      fi
      if [ "$match" = true ]; then
        echo "  - $name" >&2
        suggested=true
      fi
    done
    if [ "$suggested" = false ]; then
      echo "  (no close matches found)" >&2
    fi
    exit 3
  fi

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
      @services:*)
        # Skip service declarations - they are for devcontainer only
        continue
        ;;
      @*)
        # Skip other @ directives
        continue
        ;;
      *) eval "$out_feat_array+=(\"$local_trim\")" ;;
    esac
  done < "$f"
}

# Sort features by dependencies using topological sort
sort_features_by_deps() {
  local -n input_feats=$1
  [ ${#input_feats[@]} -eq 0 ] && return

  # Call Python script to sort features
  local sorted_output
  sorted_output=$(printf '%s\n' "${input_feats[@]}" | python3 "$ROOT/scripts/sort-features-by-deps.py" 2>&1)
  local exit_code=$?

  if [ $exit_code -ne 0 ]; then
    echo "Warning: Feature dependency sort failed, using original order" >&2
    return
  fi

  # Replace input array with sorted features
  input_feats=()
  while IFS= read -r feature; do
    [ -n "$feature" ] && input_feats+=("$feature")
  done <<< "$sorted_output"
}

# Expand feature dependencies (resolves bundle meta-features)
expand_feature_deps() {
  local -n input_feats=$1
  [ ${#input_feats[@]} -eq 0 ] && return

  # Call Python script to expand dependencies
  local expanded_output
  expanded_output=$(printf '%s\n' "${input_feats[@]}" | python3 "$ROOT/scripts/expand-feature-deps.py" 2>&1)
  local exit_code=$?

  if [ $exit_code -ne 0 ]; then
    echo "Warning: Feature dependency expansion failed, using original list" >&2
    return
  fi

  # Replace input array with expanded features
  input_feats=()
  while IFS= read -r feature; do
    [ -n "$feature" ] && input_feats+=("$feature")
  done <<< "$expanded_output"
}

emit_run_features() {
  local -n feats=$1
  [ ${#feats[@]} -eq 0 ] && return
  # Emit per-feature bind mounts and BuildKit cache mounts for optimal layer caching
  echo "RUN \\" >> "$OUT"

  # Per-feature bind mounts (read-only)
  for feat in "${feats[@]}"; do
    echo "  --mount=type=bind,source=features/${feat},target=/tmp/features/${feat},readonly \\" >> "$OUT"
  done

  # Shared bind mounts (read-only)
  echo "  --mount=type=bind,source=inputs,target=/tmp/inputs,readonly \\" >> "$OUT"
  echo "  --mount=type=bind,source=artefacts,target=/tmp/artefacts,readonly \\" >> "$OUT"
  echo "  --mount=type=bind,source=scripts,target=/tmp/scripts,readonly \\" >> "$OUT"

  # BuildKit cache mounts for performance (shared across builds)
  echo "  --mount=type=cache,target=/var/cache/apt,sharing=locked \\" >> "$OUT"
  echo "  --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \\" >> "$OUT"
  echo "  --mount=type=cache,target=/opt/toolcache,sharing=locked \\" >> "$OUT"
  echo "  --mount=type=cache,target=/root/.cache,sharing=locked \\" >> "$OUT"
  echo "  --mount=type=cache,target=/home/jovyan/.cache,sharing=locked,uid=1001,gid=1001 \\" >> "$OUT"

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
  echo "  done; apt-get clean; rm -rf /var/lib/apt/lists/auxfiles /var/lib/apt/lists/lock /var/lib/apt/lists/partial'" >> "$OUT"
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

COPY scripts/lib/helpers.sh /opt/solen/_lib/helpers.sh
COPY inputs /opt/solen/inputs
COPY artefacts /opt/solen/artefacts
ENV FEATURE_HELPERS_DIR=/opt/solen/_lib INPUTS_DIR=/opt/solen/inputs ARTEFACTS_DIR=/opt/solen/artefacts
RUN mkdir -p /opt/.features /scripts && \\
    printf "source /opt/solen/_lib/helpers.sh || true" > /scripts/lib/features.sh
EOF

# If a prebaked toolcache exists in the repo, copy it into the image
# so generated builds can reuse local artefacts instead of downloading.
if [ -d "$ROOT/generated/toolcache" ]; then
  echo "# Inject prebaked toolcache from repository" >> "$OUT"
  echo "COPY generated/toolcache /opt/toolcache" >> "$OUT"
  echo "RUN chmod -R a+rX /opt/toolcache || true" >> "$OUT"
fi

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
  # Expand any matrix files found under profiles/matrix/ (json, yaml, yml)
  MATRIX_DIR="$ROOT/profiles/matrix"
  # Remove all previously generated profiles to ensure clean generation
  rm -rf "$ROOT/generated/profiles" || true
  mkdir -p "$ROOT/generated/profiles"
  if [ -d "$MATRIX_DIR" ]; then
    for mat in "$MATRIX_DIR"/*.{yaml,yml}; do
      [ -e "$mat" ] || continue
      echo "Expanding profile matrix: $mat"
      python3 "$ROOT/scripts/generate-profiles-matrix.py" --matrix "$mat" --out "$ROOT/generated/profiles" --prefix "" || true
    done
  fi

  # Also expand a top-level profiles/matrix.yaml if present
  top="$ROOT/profiles/matrix.yaml"
  if [ -f "$top" ]; then
    echo "Expanding profile matrix: $top"
    python3 "$ROOT/scripts/generate-profiles-matrix.py" --matrix "$top" --out "$ROOT/generated/profiles" --prefix "" || true
  fi

  # Collect profiles from repo and generated folder
  for f in "$PROFILES_DIR"/*; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    [[ "$name" == "README.md" || "$name" == "base" ]] && continue
    profiles+=("$name")
  done
  if [ -d "$ROOT/generated/profiles" ]; then
    for f in "$ROOT/generated/profiles"/*; do
      [ -f "$f" ] || continue
      name=$(basename "$f")
      [[ "$name" == "README.md" || "$name" == "base" ]] && continue
      profiles+=("$name")
    done
  fi
  # Normalize profile names to remove accidental duplicated halves like
  # "java-25-java-25" -> "java-25" or
  # "quarto-lecture-java-25-quarto-lecture-java-25" -> "quarto-lecture-java-25"
  normalized_profiles=()
  for p in "${profiles[@]}"; do
    IFS='-' read -r -a toks <<< "$p"
    tlen=${#toks[@]}
    if [ $((tlen % 2)) -eq 0 ] && [ $tlen -gt 0 ]; then
      half=$((tlen/2))
      first_half=("${toks[@]:0:$half}")
      second_half=("${toks[@]:$half:$half}")
      equal=true
      for i in "${!first_half[@]}"; do
        if [ "${first_half[$i]}" != "${second_half[$i]}" ]; then equal=false; break; fi
      done
      if [ "$equal" = true ]; then
        # join first_half
        normalized_profiles+=("$(IFS=-; echo "${first_half[*]}")")
        continue
      fi
    fi
    normalized_profiles+=("$p")
  done
  # Remove duplicates and sort
  IFS=$'\n' profiles=($(printf "%s\n" "${normalized_profiles[@]}" | sort -u -V))
  unset IFS

  declare -A full_feat_lists
  for p in "${profiles[@]}"; do
    unset VISITED; declare -A VISITED
    declare -a p_feats=()
    declare -a p_envs=()
    expand_profile "$p" p_feats p_envs

    # Expand bundle dependencies (resolves meta-features)
    expand_feature_deps p_feats

    # Sort expanded features by dependencies to ensure correct install order
    sort_features_by_deps p_feats

    # Since profiles are now flattened (no @parent hierarchy),
    # all features in the profile are emitted directly from base
    parent_stage="base"

    # All features are "unique" since there's no parent to inherit from
    declare -a unique_feats=("${p_feats[@]}")

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

elif [ -n "$PROFILE" ]; then
  # Single profile mode
  unset VISITED; declare -A VISITED
  declare -a p_feats=()
  declare -a p_envs=()
  expand_profile "$PROFILE" p_feats p_envs

  # Expand bundle dependencies (resolves meta-features)
  expand_feature_deps p_feats

  # Sort expanded features by dependencies to ensure correct install order
  sort_features_by_deps p_feats

  echo -e "\n# --- Profile: $PROFILE ---" >> "$OUT"
  echo "FROM base AS profile-$PROFILE" >> "$OUT"

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
LABEL org.solen.profile="$PROFILE" \\
      org.solen.features.added="${p_feats[*]:-none}" \\
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

  emit_run_features p_feats
  echo "FROM profile-$PROFILE AS final" >> "$OUT"

fi
