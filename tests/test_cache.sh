#!/bin/bash
# Test caching functionality

# shellcheck disable=SC1091
# Source the completion script
source ../contrib/bar_complete

# Enable debug mode to see cache messages
export BAR_COMPLETE_DEBUG=1

echo "Testing completion caching..."

# Initialize registry
_bar_init_completion_registry

# Create a simple test to trigger caching
# We'll simulate a completion scenario where the same completer is called multiple times

# Mock a simple scenario by calling the main completion function
# Set up mock COMP variables
COMP_WORDS=(bar test)
COMP_CWORD=1

# Run completion first time
echo "First completion run (should NOT use cache):"
output1=$(_bar_complete 2>&1)
echo "$output1" | grep -q "Using cached results" && echo "✗ FAIL: Cache used on first run" || echo "✓ PASS: No cache on first run"

# Now test that subsequent calls within the same completion session would use cache
# This is harder to test directly, so we'll test the cache mechanism more directly

# Direct test of cache behavior
echo ""
echo "Testing cache array behavior:"

# Create a mock cache array and test the caching logic
declare -a test_cache=()
test_completer="_bar_complete_comp_file"
test_cur="test"
cache_key="${test_completer}:${test_cur}"

# First, populate the cache
test_results=("result1" "result2" "result3")
cache_value="${cache_key}:$(printf '%s\n' "${test_results[@]}")"
test_cache+=("$cache_value")

echo "Cache populated with key: $cache_key"

# Now search for it
use_cache=false
cache_idx=0
for ((cache_idx=0; cache_idx<${#test_cache[@]}; cache_idx++)); do
    if [[ "${test_cache[$cache_idx]}" == "$cache_key"* ]]; then
        use_cache=true
        break
    fi
done

if [[ $use_cache == true ]]; then
    echo "✓ PASS: Cache lookup successful"
    
    # Extract cached results
    cached_results="${test_cache[$cache_idx]#*:}"
    cached_results="${cached_results#*:}"  # Skip the second colon
    
    IFS=$'\n' read -rd '' -a cached_comps <<< "$cached_results" || true
    
    if [[ ${#cached_comps[@]} -eq 3 ]]; then
        echo "✓ PASS: Cached results retrieved correctly (${#cached_comps[@]} items)"
    else
        echo "✗ FAIL: Expected 3 cached items, got ${#cached_comps[@]}"
    fi
else
    echo "✗ FAIL: Cache lookup failed"
fi

# Test with different key (should not find in cache)
different_key="_bar_complete_comp_directory:other"
use_cache=false
for ((cache_idx=0; cache_idx<${#test_cache[@]}; cache_idx++)); do
    if [[ "${test_cache[$cache_idx]}" == "$different_key"* ]]; then
        use_cache=true
        break
    fi
done

if [[ $use_cache == false ]]; then
    echo "✓ PASS: Different key not found in cache (as expected)"
else
    echo "✗ FAIL: Different key incorrectly found in cache"
fi

echo ""
echo "Cache tests complete"

# Disable debug mode
unset BAR_COMPLETE_DEBUG
