#!/usr/bin/env bash
# Validates feature dependencies and performs topological sort
# Usage: ./scripts/validate-feature-deps.sh [--profile PROFILE_PATH]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
FEATURES_DIR="${REPO_ROOT}/.devcontainer/features"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

errors=0
warnings=0

echo "Feature Dependency Validator"
echo "=============================="
echo ""

# Parse all feature.json files and build dependency graph
declare -A feature_ids
declare -A feature_depends_on
declare -A feature_files

echo "📦 Discovering features..."
for feature_json in "${FEATURES_DIR}"/*/feature.json; do
    if [ ! -f "$feature_json" ]; then
        continue
    fi
    
    feature_dir=$(basename "$(dirname "$feature_json")")
    feature_id=$(jq -r '.id // empty' "$feature_json" 2>/dev/null || echo "")
    
    if [ -z "$feature_id" ]; then
        echo -e "${YELLOW}⚠${NC}  Feature $feature_dir has no 'id' field, skipping"
        ((warnings++))
        continue
    fi
    
    feature_ids["$feature_id"]=1
    feature_files["$feature_id"]="$feature_json"
    
    # Extract dependsOn array
    depends_on=$(jq -r '.dependsOn[]? // empty' "$feature_json" 2>/dev/null || echo "")
    if [ -n "$depends_on" ]; then
        feature_depends_on["$feature_id"]="$depends_on"
    fi
done

echo "Found ${#feature_ids[@]} features"
echo ""

# Validate dependencies exist
echo "🔍 Validating dependencies..."
for feature_id in "${!feature_depends_on[@]}"; do
    deps="${feature_depends_on[$feature_id]}"
    for dep in $deps; do
        if [ -z "${feature_ids[$dep]:-}" ]; then
            echo -e "${RED}✗${NC} Feature '$feature_id' depends on '$dep' which doesn't exist"
            ((errors++))
        fi
    done
done

if [ $errors -eq 0 ]; then
    echo -e "${GREEN}✓${NC} All dependencies reference existing features"
fi
echo ""

# Check for cycles using DFS
echo "🔄 Checking for circular dependencies..."
declare -A visited
declare -A rec_stack

check_cycle() {
    local node="$1"
    visited["$node"]=1
    rec_stack["$node"]=1
    
    local deps="${feature_depends_on[$node]:-}"
    for dep in $deps; do
        if [ -z "${visited[$dep]:-}" ]; then
            if check_cycle "$dep"; then
                return 0
            fi
        elif [ "${rec_stack[$dep]:-0}" = "1" ]; then
            echo -e "${RED}✗${NC} Circular dependency detected: $node → $dep"
            ((errors++))
            return 0
        fi
    done
    
    rec_stack["$node"]=0
    return 1
}

for feature_id in "${!feature_ids[@]}"; do
    if [ -z "${visited[$feature_id]:-}" ]; then
        check_cycle "$feature_id" || true
    fi
done

if [ $errors -eq 0 ]; then
    echo -e "${GREEN}✓${NC} No circular dependencies found"
fi
echo ""

# Topological sort using Kahn's algorithm
echo "📊 Performing topological sort..."
declare -A in_degree
sorted_features=()

# Calculate in-degrees
for feature_id in "${!feature_ids[@]}"; do
    in_degree["$feature_id"]=0
done

for feature_id in "${!feature_depends_on[@]}"; do
    deps="${feature_depends_on[$feature_id]}"
    for dep in $deps; do
        if [ -n "${feature_ids[$dep]:-}" ]; then
            ((in_degree["$feature_id"]++))
        fi
    done
done

# Process features in waves (simplified algorithm)
remaining=${#feature_ids[@]}
max_iterations=$((remaining * 2))
iteration=0

while [ $remaining -gt 0 ] && [ $iteration -lt $max_iterations ]; do
    ((iteration++))
    found_any=false
    
    for feature_id in "${!feature_ids[@]}"; do
        # Skip if already processed
        if [[ " ${sorted_features[*]} " =~ " ${feature_id} " ]]; then
            continue
        fi
        
        # Check if all dependencies are satisfied
        can_add=true
        deps="${feature_depends_on[$feature_id]:-}"
        for dep in $deps; do
            if ! [[ " ${sorted_features[*]} " =~ " ${dep} " ]]; then
                can_add=false
                break
            fi
        done
        
        if $can_add; then
            sorted_features+=("$feature_id")
            ((remaining--))
            found_any=true
        fi
    done
    
    # If we didn't add any feature in this iteration, we have a cycle
    if ! $found_any; then
        break
    fi
done

if [ ${#sorted_features[@]} -ne ${#feature_ids[@]} ]; then
    echo -e "${RED}✗${NC} Topological sort failed - possible cycle or disconnected graph"
    echo "   Sorted ${#sorted_features[@]} out of ${#feature_ids[@]} features"
    ((errors++))
else
    echo -e "${GREEN}✓${NC} Topological sort successful"
    echo ""
    echo "Installation order:"
    for i in "${!sorted_features[@]}"; do
        feature_id="${sorted_features[$i]}"
        deps="${feature_depends_on[$feature_id]:-}"
        if [ -n "$deps" ]; then
            echo "  $((i+1)). $feature_id (depends on: $deps)"
        else
            echo "  $((i+1)). $feature_id"
        fi
    done
fi
echo ""

# If --profile flag provided, validate that profile
if [ "${1:-}" = "--profile" ] && [ -n "${2:-}" ]; then
    PROFILE_PATH="$2"
    echo "🔍 Validating profile: $PROFILE_PATH"
    echo ""
    
    if [ ! -f "$PROFILE_PATH" ]; then
        echo -e "${RED}✗${NC} Profile file not found: $PROFILE_PATH"
        exit 1
    fi
    
    # Extract features from profile (lines not starting with @ or #)
    profile_features=()
    while IFS= read -r line; do
        # Skip comments and directives
        if [[ "$line" =~ ^[[:space:]]*# ]] || [[ "$line" =~ ^[[:space:]]*@ ]] || [ -z "$line" ]; then
            continue
        fi
        # Extract feature name (first word)
        feature=$(echo "$line" | awk '{print $1}')
        if [ -n "$feature" ]; then
            profile_features+=("$feature")
        fi
    done < "$PROFILE_PATH"
    
    echo "Profile includes ${#profile_features[@]} features"
    
    # Validate each feature exists
    for feature in "${profile_features[@]}"; do
        if [ -z "${feature_ids[$feature]:-}" ]; then
            echo -e "${RED}✗${NC} Profile references unknown feature: $feature"
            ((errors++))
        fi
    done
    
    # Check if profile ordering respects dependencies
    declare -A profile_position
    for i in "${!profile_features[@]}"; do
        profile_position["${profile_features[$i]}"]=$i
    done
    
    for feature in "${profile_features[@]}"; do
        deps="${feature_depends_on[$feature]:-}"
        for dep in $deps; do
            if [ -n "${profile_position[$dep]:-}" ]; then
                dep_pos="${profile_position[$dep]}"
                feat_pos="${profile_position[$feature]}"
                if [ "$dep_pos" -gt "$feat_pos" ]; then
                    echo -e "${RED}✗${NC} Dependency order violated: $feature (pos $feat_pos) depends on $dep (pos $dep_pos)"
                    ((errors++))
                fi
            else
                echo -e "${YELLOW}⚠${NC}  Feature $feature depends on $dep which is not in profile"
                ((warnings++))
            fi
        done
    done
    
    if [ $errors -eq 0 ]; then
        echo -e "${GREEN}✓${NC} Profile dependency order is valid"
    fi
    echo ""
fi

# Summary
echo "Summary"
echo "-------"
echo "Total features: ${#feature_ids[@]}"
echo "Features with dependencies: ${#feature_depends_on[@]}"
echo "Errors: $errors"
echo "Warnings: $warnings"
echo ""

if [ $errors -gt 0 ]; then
    echo -e "${RED}❌ Validation failed with $errors error(s)${NC}"
    exit 1
elif [ $warnings -gt 0 ]; then
    echo -e "${YELLOW}⚠️  Validation passed with $warnings warning(s)${NC}"
    exit 0
else
    echo -e "${GREEN}✅ All validations passed!${NC}"
    exit 0
fi
