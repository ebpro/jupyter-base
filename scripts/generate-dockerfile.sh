#!/usr/bin/env bash
set -euo pipefail

# Ensure this script runs under Bash 4+ (associative arrays are used)
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  cat <<'MSG' >&2
Error: this script requires Bash 4 or newer (associative arrays are used).

On macOS the system bash is often v3. To fix, install a newer bash and run the
build using that shell. Example using Homebrew:

  brew install bash
  "$(brew --prefix 2>/dev/null || echo /usr/local)"/bin/bash ./build.sh --all-profiles

Alternatively run the build inside a Linux container/VM or on CI that provides
bash >= 4.
MSG
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILES_DIR="$ROOT/profiles"
FEATURES_DIR="$ROOT/.devcontainer/features"

usage(){
  cat <<EOF
Usage: $(basename "$0") [--profile <name>] [--all-profiles] [--out Dockerfile] [--dry-run]

Generates a Dockerfile by composing features listed in a profile or for all profiles.
If --all-profiles is provided, a multi-stage Dockerfile is emitted with a 'common' stage
when `profiles/base` exists.
EOF
}

PROFILE=""
OUT="Dockerfile.generated"
DRY=false
ALL=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --profile) PROFILE="$2"; shift 2 ;;
    --all-profiles) ALL=true; shift ;;
    --out) OUT="$2"; shift 2 ;;
    --dry-run) DRY=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

declare -A VISITED

expand_profile(){
  local pname="$1"
  local out_name="$2"
  if [ -n "${VISITED[$pname]:-}" ]; then
    return
  fi
  VISITED[$pname]=1
  local f="$PROFILES_DIR/$pname"
  if [ ! -f "$f" ]; then
    echo "Profile not found: $pname" >&2; exit 3
  fi
  local line local_trim parent sub
  while IFS= read -r line || [ -n "$line" ]; do
    local_trim="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$local_trim" ] && continue
    case "$local_trim" in
      \#*) continue ;;
      @parent:*)
        parent=${local_trim#@parent:}
        parent="$(echo "$parent" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        expand_profile "$parent" "$out_name"
        ;;
      @profile:*)
        sub=${local_trim#@profile:}
        sub="$(echo "$sub" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        expand_profile "$sub" "$out_name"
        ;;
      *)
        # append to the array whose name is in out_name
        eval "$out_name+=(\"$local_trim\")"
        ;;
    esac
  done < "$f"
}

collect_profiles(){
  profiles=()
  for f in "$PROFILES_DIR"/*; do
    name=$(basename "$f")
    [ "$name" = "README.md" ] && continue
    profiles+=("$name")
  done
  # Sort profiles using version sort so numeric prefixes order naturally (00-01 before 10-00)
  if [ ${#profiles[@]} -gt 0 ]; then
    IFS=$'\n' read -r -d '' -a profiles < <(printf "%s\n" "${profiles[@]}" | sort -V && printf '\0')
  fi
}

if [ "$ALL" = true ]; then
  collect_profiles
  # If base profile exists, expand it as common
  common_features=()
  if [ -f "$PROFILES_DIR/base" ]; then
    expand_profile "base" common_features
  fi
  # Expand each profile into resolved list and store as parallel arrays
  profile_features_strings=()
  i=0
  declare -A full_features_map
  for p in "${profiles[@]}"; do
    arr=()
    expand_profile "$p" arr
    # deduplicate per-profile preserve order
    dedup=()
    declare -A seen
    for item in "${arr[@]}"; do
      if [ -z "${seen[$item]:-}" ]; then
        dedup+=("$item")
        seen[$item]=1
      fi
    done
    profile_features_strings[$i]="${dedup[*]}"
    # store full resolved features for this profile for later use
    full_features_map[$p]="${dedup[*]}"
    i=$((i+1))
  done

  # Build parent map and topological order of profiles so parents are emitted before children
  declare -A parent_map
  for p in "${profiles[@]}"; do
    parent=""
    if [ -f "$PROFILES_DIR/$p" ]; then
      parent_line=$(grep -E '^[[:space:]]*@parent:' "$PROFILES_DIR/$p" || true)
      if [ -n "$parent_line" ]; then
        parent=${parent_line#@parent:}
        parent=$(echo "$parent" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      fi
    fi
    parent_map[$p]="$parent"
  done

  ordered_profiles=()
  processed=()
  remain=("${profiles[@]}")
  while [ ${#remain[@]} -gt 0 ]; do
    progressed=false
    next_remain=()
    for p in "${remain[@]}"; do
      par=${parent_map[$p]:-}
      if [ -z "$par" ] || [[ " ${ordered_profiles[*]} " == *" $par "* ]]; then
        ordered_profiles+=("$p")
        progressed=true
      else
        next_remain+=("$p")
      fi
    done
    if [ "$progressed" = false ]; then
      echo "Error: cannot resolve profile order (possible cycle or missing parent)" >&2; exit 3
    fi
    remain=("${next_remain[@]}")
  done

  # Compute per-profile unique features (features not present in parent)
  declare -A unique_features_map
  for p in "${ordered_profiles[@]}"; do
    par=${parent_map[$p]:-}
    parent_feats=()
    if [ -n "$par" ]; then
      IFS=' ' read -r -a parent_feats <<< "${full_features_map[$par]:-}"
    fi
    IFS=' ' read -r -a all_feats <<< "${full_features_map[$p]:-}"
    uniq=()
    for f in "${all_feats[@]}"; do
      skip=false
      for pf in "${parent_feats[@]}"; do
        if [ "$pf" = "$f" ]; then skip=true; break; fi
      done
      if [ "$skip" = false ]; then uniq+=("$f"); fi
    done
    unique_features_map[$p]="${uniq[*]}"
  done

  if [ "$DRY" = true ]; then
    echo "Profiles resolved:"
    for idx in "${!profiles[@]}"; do
      p=${profiles[$idx]}
      echo "- $p: ${profile_features_strings[$idx]}"
    done
    exit 0
  fi

  # Emit Dockerfile with common stage if present
  cat > "$OUT" <<'EOF'
# Generated multi-profile Dockerfile
ARG VARIANT="ubuntu-24.04"
# Use an explicit default base image tag to avoid buildx warnings when ARG has a default
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04 AS base
ARG NB_USER=jovyan
ARG NB_UID=1001
ARG NB_GID=1001
ENV HOME=/home/jovyan
WORKDIR /home/jovyan

EOF
    # Ensure shared helpers and Artefacts are available in base so feature scripts
    # that run early (before a 'common' stage) can source helper functions.
    echo "# Bake helper library and Artefacts into the base stage" >> "$OUT"
    echo "COPY shared/_lib/helpers.sh /opt/solen/_lib/helpers.sh" >> "$OUT"
    echo "COPY Artefacts /opt/solen/Artefacts" >> "$OUT"
    echo "ENV FEATURE_HELPERS_DIR=/opt/solen/_lib ARTIFACTS_DIR=/opt/solen/Artefacts" >> "$OUT"
    echo "RUN mkdir -p /opt/.features || true" >> "$OUT"

  if [ ${#common_features[@]} -gt 0 ]; then
    echo "# Common stage" >> "$OUT"
    echo "FROM base AS common" >> "$OUT"
    # bake helper scripts and Artefacts into the common stage so runtime features can source them
    echo "# Bake helper library and Artefacts into image" >> "$OUT"
    echo "COPY shared/_lib/helpers.sh /opt/solen/_lib/helpers.sh" >> "$OUT"
    echo "COPY Artefacts /opt/solen/Artefacts" >> "$OUT"
    echo "ENV FEATURE_HELPERS_DIR=/opt/solen/_lib ARTIFACTS_DIR=/opt/solen/Artefacts" >> "$OUT"
    echo "RUN mkdir -p /opt/.features || true" >> "$OUT"
    for feat in "${common_features[@]}"; do
      echo "# Feature: $feat" >> "$OUT"
      echo "COPY .devcontainer/features/$feat /tmp/features/$feat" >> "$OUT"
        cat >> "$OUT" <<RUNBLOCK
RUN --mount=type=bind,source=Artefacts,target=/tmp/Artefacts \
  bash -eux -c 'mkdir -p /scripts; printf "%s\n" "source /opt/solen/_lib/helpers.sh || true" > /scripts/feature_helpers.sh; if [ -x /tmp/features/$feat/install.sh ]; then /tmp/features/$feat/install.sh; else echo "No install.sh for $feat"; fi; rm -rf /tmp/features/$feat'
RUNBLOCK
      echo >> "$OUT"
    done
  fi

  # Emit per-profile stages in topological order so parent stages are available
  # reset visited map so expand_profile can be used again per-profile
  unset VISITED || true
  declare -A VISITED
  for p in "${ordered_profiles[@]}"; do
    echo "# Profile: $p" >> "$OUT"
    par=${parent_map[$p]:-}
    # determine base stage to inherit from (parent stage or common/base image)
    if [ -n "$par" ]; then
      # If parent had unique features a `profile-<parent>` stage was emitted;
      # otherwise parent collapsed to `final-<parent>` and we should inherit from that.
      parent_unique="${unique_features_map[$par]:-}"
      if [ -n "$parent_unique" ]; then
        base_from="profile-$par"
      else
        base_from="final-$par"
      fi
    elif [ ${#common_features[@]} -gt 0 ]; then
      base_from="common"
    else
      base_from="base"
    fi

    # Recompute resolved features for this profile and subtract parent features
    arr=()
    expand_profile "$p" arr
    # deduplicate while preserving order
    dedup=()
    declare -A _seen_local
    for item in "${arr[@]}"; do
      if [ -z "${_seen_local[$item]:-}" ]; then
        dedup+=("$item")
        _seen_local[$item]=1
      fi
    done
    # parent features
    par_feats=()
    if [ -n "$par" ]; then
      IFS=' ' read -r -a par_feats <<< "${full_features_map[$par]:-}"
    fi
    # compute unique features for this profile (exclude parent features)
    prof_feats=()
    for f in "${dedup[@]}"; do
      skip=false
      for pf in "${par_feats[@]}"; do
        if [ "$pf" = "$f" ]; then skip=true; break; fi
      done
      if [ "$skip" = false ]; then prof_feats+=("$f"); fi
    done

    if [ ${#prof_feats[@]} -eq 0 ]; then
      # no unique features; collapse stage and alias final directly to base
      echo "FROM $base_from AS final-$p" >> "$OUT"
      echo >> "$OUT"
      continue
    fi

    # otherwise create a profile stage that inherits from the base and apply unique features
    echo "FROM $base_from AS profile-$p" >> "$OUT"
    for feat in "${prof_feats[@]}"; do
      # skip features that are in common_features (they were applied in common stage)
      skip=false
      for cf in "${common_features[@]}"; do
        if [ "$cf" = "$feat" ]; then skip=true; break; fi
      done
      if [ "$skip" = true ]; then continue; fi
      echo "# Feature: $feat" >> "$OUT"
      echo "COPY .devcontainer/features/$feat /tmp/features/$feat" >> "$OUT"
        cat >> "$OUT" <<RUNBLOCK
RUN --mount=type=bind,source=Artefacts,target=/tmp/Artefacts \
  bash -eux -c 'mkdir -p /scripts; printf "%s\n" "source /opt/solen/_lib/helpers.sh || true" > /scripts/feature_helpers.sh; if [ -x /tmp/features/$feat/install.sh ]; then /tmp/features/$feat/install.sh; else echo "No install.sh for $feat"; fi; rm -rf /tmp/features/$feat'
RUNBLOCK
      echo >> "$OUT"
    done
    echo "FROM profile-$p AS final-$p" >> "$OUT"
    echo >> "$OUT"
  done

  echo "Dockerfile generated to $OUT"
  exit 0
fi

# Single-profile mode (unchanged behavior)
if [ -z "$PROFILE" ]; then
  echo "--profile is required unless --all-profiles is used" >&2; usage; exit 2
fi

declare -a RESOLVED
expand_profile "$PROFILE" RESOLVED

# validate features exist
for feat in "${RESOLVED[@]}"; do
  if [ ! -d "$FEATURES_DIR/$feat" ]; then
    echo "Feature not found: $feat (expected $FEATURES_DIR/$feat)" >&2
    exit 4
  fi
done

if [ "$DRY" = true ]; then
  echo "Resolved features for profile '$PROFILE':"
  for f in "${RESOLVED[@]}"; do echo " - $f"; done
  exit 0
fi

# Emit header for single-profile Dockerfile. Use printf to insert the profile
# but keep the VARIANT token literal (escaped) so the generated Dockerfile has
# `ARG VARIANT` and `FROM ...:${VARIANT}` instead of expanding it here.
: > "$OUT"
printf "# Generated Dockerfile for profile: %s\n" "$PROFILE" >> "$OUT"
printf 'ARG VARIANT="ubuntu-24.04"\n' >> "$OUT"
printf '# Use the VARIANT in the FROM and name the stage so --target final-<profile> works\n' >> "$OUT"
printf "FROM mcr.microsoft.com/devcontainers/base:\${VARIANT} AS final-%s\n\n" "$PROFILE" >> "$OUT"
printf 'LABEL org.solen.profile="%s"\n\n' "$PROFILE" >> "$OUT"
printf 'ENV NB_USER=jovyan NB_UID=1001 NB_GID=1001 HOME=/home/jovyan\n\n' >> "$OUT"
printf 'WORKDIR /home/jovyan\n\n' >> "$OUT"

# Bake helper library and Artefacts into the image early so feature install
# scripts can source helper functions during their RUN steps.
echo "# Bake helper library and Artefacts into the image" >> "$OUT"
echo "COPY shared/_lib/helpers.sh /opt/solen/_lib/helpers.sh" >> "$OUT"
echo "COPY Artefacts /opt/solen/Artefacts" >> "$OUT"
echo "ENV FEATURE_HELPERS_DIR=/opt/solen/_lib ARTIFACTS_DIR=/opt/solen/Artefacts" >> "$OUT"
echo "RUN mkdir -p /opt/.features || true" >> "$OUT"
for feat in "${RESOLVED[@]}"; do
  echo "# Feature: $feat" >> "$OUT"
  echo "COPY .devcontainer/features/$feat /tmp/features/$feat" >> "$OUT"
        cat >> "$OUT" <<RUNBLOCK
RUN --mount=type=bind,source=Artefacts,target=/tmp/Artefacts \
  bash -eux -c 'mkdir -p /scripts; printf "%s\n" "source /opt/solen/_lib/helpers.sh || true" > /scripts/feature_helpers.sh; if [ -x /tmp/features/$feat/install.sh ]; then /tmp/features/$feat/install.sh; else echo "No install.sh for $feat"; fi; rm -rf /tmp/features/$feat'
RUNBLOCK
done



echo "Dockerfile generated to $OUT"
exit 0
