#!/usr/bin/env bash
set -euo pipefail

# Test All Features Script
# Orchestrates testing of multiple features with reporting
# Usage: ./scripts/test-all-features.sh [OPTIONS]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FEATURES_DIR="$ROOT_DIR/.devcontainer/features"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_pass() { echo -e "${GREEN}✓${NC} $1"; }
log_fail() { echo -e "${RED}✗${NC} $1"; }
log_warn() { echo -e "${YELLOW}⚠${NC}  $1"; }
log_info() { echo -e "${BLUE}→${NC} $1"; }

# Default options
BUILD_IMAGES=false
PARALLEL=false
MAX_JOBS=4
VERBOSE=false
FEATURES_TO_TEST=""
REPORT_FILE=""

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Test multiple features with build and validation.

Options:
  --build              Build test images for each feature
  --parallel           Run tests in parallel (max $MAX_JOBS jobs)
  --jobs N             Set max parallel jobs (default: $MAX_JOBS)
  --features LIST      Comma-separated list of features to test (default: all)
  --verbose, -v        Show detailed output
  --report FILE        Write results to JSON report file
  --help, -h           Show this help message

Examples:
  # Test all features (using existing images)
  $0

  # Build and test all features
  $0 --build

  # Test specific features in parallel
  $0 --features node,python-base,gh-cli --parallel --build

  # Generate JSON report
  $0 --build --report test-results.json

EOF
  exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --build)
      BUILD_IMAGES=true
      shift
      ;;
    --parallel)
      PARALLEL=true
      shift
      ;;
    --jobs)
      MAX_JOBS="$2"
      shift 2
      ;;
    --features)
      FEATURES_TO_TEST="$2"
      shift 2
      ;;
    --verbose|-v)
      VERBOSE=true
      shift
      ;;
    --report)
      REPORT_FILE="$2"
      shift 2
      ;;
    --help|-h)
      usage
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      ;;
  esac
done

echo "===================================================================="
echo "Feature Testing Suite"
echo "===================================================================="
log_info "Features directory: $FEATURES_DIR"
log_info "Build images: $BUILD_IMAGES"
log_info "Parallel mode: $PARALLEL"
[ "$PARALLEL" = true ] && log_info "Max parallel jobs: $MAX_JOBS"
echo

# Discover features to test
if [ -n "$FEATURES_TO_TEST" ]; then
  IFS=',' read -ra FEATURES <<< "$FEATURES_TO_TEST"
else
  # Find all features with feature.json
  FEATURES=()
  for feature_dir in "$FEATURES_DIR"/*; do
    if [ -d "$feature_dir" ] && [ -f "$feature_dir/feature.json" ]; then
      feature_name=$(basename "$feature_dir")
      # Skip _lib features (they're libraries, not installable features)
      [[ "$feature_name" == _lib ]] && continue
      FEATURES+=("$feature_name")
    fi
  done
fi

log_info "Found ${#FEATURES[@]} features to test"
echo

# Test results tracking
declare -A RESULTS
TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0

# Create temporary directory for logs
LOG_DIR=$(mktemp -d)
trap "rm -rf $LOG_DIR" EXIT

# Function to test a single feature
test_feature() {
  local feature="$1"
  local log_file="$LOG_DIR/${feature}.log"
  
  echo "Testing: $feature" >> "$log_file"
  
  # Check if feature exists
  if [ ! -d "$FEATURES_DIR/$feature" ]; then
    echo "SKIP: Feature directory not found" >> "$log_file"
    return 2
  fi
  
  # Check if feature.json exists
  if [ ! -f "$FEATURES_DIR/$feature/feature.json" ]; then
    echo "SKIP: feature.json not found" >> "$log_file"
    return 2
  fi
  
  # Check if install.sh exists
  if [ ! -f "$FEATURES_DIR/$feature/install.sh" ]; then
    echo "SKIP: install.sh not found" >> "$log_file"
    return 2
  fi
  
  # Build test image if requested
  if [ "$BUILD_IMAGES" = true ]; then
    if [ "$VERBOSE" = true ]; then
      "$SCRIPT_DIR/test-feature.sh" "$feature" --build-first --verbose >> "$log_file" 2>&1
    else
      "$SCRIPT_DIR/test-feature.sh" "$feature" --build-first >> "$log_file" 2>&1
    fi
    local result=$?
  else
    # Check if test image exists
    if docker image inspect "feature-test-${feature}:latest" >/dev/null 2>&1; then
      if [ "$VERBOSE" = true ]; then
        "$SCRIPT_DIR/test-feature.sh" "$feature" --verbose >> "$log_file" 2>&1
      else
        "$SCRIPT_DIR/test-feature.sh" "$feature" >> "$log_file" 2>&1
      fi
      local result=$?
    else
      echo "SKIP: Test image not found (use --build to create)" >> "$log_file"
      return 2
    fi
  fi
  
  return $result
}

# Run tests
echo "===================================================================="
echo "Running Tests"
echo "===================================================================="
echo

if [ "$PARALLEL" = true ]; then
  # Parallel execution
  log_info "Running tests in parallel (max $MAX_JOBS jobs)..."
  echo
  
  # GNU parallel or xargs for parallel execution
  if command -v parallel >/dev/null 2>&1; then
    # Use GNU parallel
    printf '%s\n' "${FEATURES[@]}" | parallel -j "$MAX_JOBS" test_feature {}
  else
    # Fallback to xargs
    printf '%s\n' "${FEATURES[@]}" | xargs -n 1 -P "$MAX_JOBS" -I {} bash -c "test_feature {}"
  fi
  
  # Collect results from logs
  for feature in "${FEATURES[@]}"; do
    ((TOTAL++)) || true
    
    if [ -f "$LOG_DIR/${feature}.log" ]; then
      if grep -q "All tests passed!" "$LOG_DIR/${feature}.log" 2>/dev/null; then
        RESULTS["$feature"]="PASS"
        ((PASSED++)) || true
      elif grep -q "^SKIP:" "$LOG_DIR/${feature}.log" 2>/dev/null; then
        RESULTS["$feature"]="SKIP"
        ((SKIPPED++)) || true
      else
        RESULTS["$feature"]="FAIL"
        ((FAILED++)) || true
      fi
    else
      RESULTS["$feature"]="UNKNOWN"
      ((FAILED++)) || true
    fi
  done
  
else
  # Sequential execution
  for feature in "${FEATURES[@]}"; do
    ((TOTAL++)) || true
    
    log_info "[$TOTAL/${#FEATURES[@]}] Testing: $feature"
    
    if test_feature "$feature"; then
      log_pass "$feature"
      RESULTS["$feature"]="PASS"
      ((PASSED++)) || true
    else
      local exit_code=$?
      if [ $exit_code -eq 2 ]; then
        log_warn "$feature (skipped)"
        RESULTS["$feature"]="SKIP"
        ((SKIPPED++)) || true
      else
        log_fail "$feature"
        RESULTS["$feature"]="FAIL"
        ((FAILED++)) || true
        
        # Show error details
        if [ -f "$LOG_DIR/${feature}.log" ]; then
          echo "  Last 10 lines of log:"
          tail -10 "$LOG_DIR/${feature}.log" | sed 's/^/  /'
        fi
      fi
    fi
    echo
  done
fi

# Print detailed results
echo
echo "===================================================================="
echo "Detailed Results"
echo "===================================================================="

for feature in "${FEATURES[@]}"; do
  result="${RESULTS[$feature]:-UNKNOWN}"
  case "$result" in
    PASS)
      log_pass "$feature"
      ;;
    FAIL)
      log_fail "$feature"
      ;;
    SKIP)
      log_warn "$feature (skipped)"
      ;;
    *)
      log_warn "$feature (unknown)"
      ;;
  esac
done

# Summary
echo
echo "===================================================================="
echo "Summary"
echo "===================================================================="
echo "Total features: $TOTAL"
echo "Passed: $PASSED"
echo "Failed: $FAILED"
echo "Skipped: $SKIPPED"
echo "===================================================================="

# Generate JSON report if requested
if [ -n "$REPORT_FILE" ]; then
  log_info "Writing report to: $REPORT_FILE"
  
  cat > "$REPORT_FILE" <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "total": $TOTAL,
  "passed": $PASSED,
  "failed": $FAILED,
  "skipped": $SKIPPED,
  "results": {
EOF
  
  first=true
  for feature in "${FEATURES[@]}"; do
    [ "$first" = false ] && echo "," >> "$REPORT_FILE"
    first=false
    result="${RESULTS[$feature]:-UNKNOWN}"
    echo -n "    \"$feature\": \"$result\"" >> "$REPORT_FILE"
  done
  
  cat >> "$REPORT_FILE" <<EOF

  }
}
EOF
  
  log_pass "Report written successfully"
fi

# Exit with appropriate code
if [ $FAILED -eq 0 ]; then
  echo -e "${GREEN}✓ All tests passed!${NC}"
  exit 0
else
  echo -e "${RED}✗ Some tests failed${NC}"
  exit 1
fi
