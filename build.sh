#!/bin/bash
# Simple CLI parsing: accepts a profile name (positional) and flags
# Flags: --no-cache, --push, --load
# Default behavior: if neither --push nor --load provided, use --load

# Activate project venv if available
if [ -f "./.venv/bin/activate" ]; then
	# prefer workspace-local venv when running from repo
	# shellcheck disable=SC1091
	source "./.venv/bin/activate"
fi

# parse args
PROFILE=""
NO_CACHE=0
DO_PUSH=0
DO_LOAD=0
DO_MULTIARCH=0
for arg in "$@"; do
	case "$arg" in
		--no-cache)
			NO_CACHE=1
			;;
		--push)
			DO_PUSH=1
			;;
		--multi-arch)
			DO_MULTIARCH=1
			;;
		--load)
			DO_LOAD=1
			;;
		-h|--help)
			echo "Usage: $0 [profile] [--load] [--push] [--no-cache] [--multi-arch]"
			exit 0
			;;
		*)
			if [ -z "$PROFILE" ]; then
				PROFILE="$arg"
			fi
			;;
	esac
done

if [ -z "$PROFILE" ]; then
	PROFILE="quarto-full"
fi

# default to load if neither specified
if [ "$DO_LOAD" -eq 0 ] && [ "$DO_PUSH" -eq 0 ]; then
	DO_LOAD=1
fi

# Prepare log directory
LOGDIR="generated/build-logs"
mkdir -p "$LOGDIR"
TS=$(date -u +%Y%m%dT%H%M%SZ)
LOGFILE="$LOGDIR/${PROFILE}-$TS.log"
echo "Build started: $(date -u)" | tee "$LOGFILE"

run_step() {
	STEP_NAME="$1"
	echo "\n=== STEP: $STEP_NAME ===" | tee -a "$LOGFILE"
	shift
	cmd="$*"
	bash -c "$cmd" 2>&1 | tee -a "$LOGFILE"
	rc=${PIPESTATUS[0]}
	if [ $rc -ne 0 ]; then
		echo "STEP FAILED: $STEP_NAME (rc=$rc)" | tee -a "$LOGFILE"
		echo "Build aborted: $(date -u)" | tee -a "$LOGFILE"
		ln -sf "$(basename "$LOGFILE")" "$LOGDIR/latest.log"
		exit $rc
	fi
}

# Generate profiles
run_step "generate-profiles" "PYTHONPATH=solen-cli python -m solen.cli generate profiles --matrix profiles/matrix --out generated/profiles --chain"

# Build images: assemble build flags from options
# Default: empty (use host/local build). Enable multi-arch when requested.
if [ "$DO_MULTIARCH" -eq 1 ]; then
	PLATFORMS="linux/amd64,linux/arm64"
else
	PLATFORMS=""
fi

if [ "$DO_PUSH" -eq 1 ]; then
	# When pushing, generate Dockerfile + bake and invoke buildx bake with --push
	run_step "generate-dockerfile" "PYTHONPATH=solen-cli python -m solen.cli generate dockerfile --all --output generated/Dockerfile"
	run_step "generate-bake" "PYTHONPATH=solen-cli python -m solen.cli generate bake --output generated/docker-bake.hcl"

	BAKE_TARGET="final-$PROFILE"

	BAKE_CMD=(docker buildx bake --file generated/docker-bake.hcl "$BAKE_TARGET")

	# set platforms (only if PLATFORMS is non-empty)
	if [ -n "$PLATFORMS" ]; then
		BAKE_CMD+=(--set "*.platform=${PLATFORMS}")
	fi

	if [ "$NO_CACHE" -eq 1 ]; then
		BAKE_CMD+=(--set "*.no-cache=true")
	fi

	if [ "$DO_LOAD" -eq 1 ]; then
		BAKE_CMD+=(--load)
	fi

	BAKE_CMD+=(--push)

	# run bake (join args for bash -c)
	bake_cmd_str=""
	for a in "${BAKE_CMD[@]}"; do
		bake_cmd_str+="$(printf '%s ' "${a}")"
	done
	run_step "docker-bake" "$bake_cmd_str"
else
	BUILD_CMD="PYTHONPATH=solen-cli python -m solen.cli build --profile \"$PROFILE\""
	if [ -n "$PLATFORMS" ]; then
		BUILD_CMD="$BUILD_CMD --platforms ${PLATFORMS}"
	fi
	if [ "$DO_LOAD" -eq 1 ]; then
		BUILD_CMD="$BUILD_CMD --load"
	fi
	if [ "$NO_CACHE" -eq 1 ]; then
		BUILD_CMD="$BUILD_CMD --no-cache"
	fi
	run_step "build-profile" "$BUILD_CMD"
fi

echo "Build finished: $(date -u)" | tee -a "$LOGFILE"
ln -sf "$(basename "$LOGFILE")" "$LOGDIR/latest.log"

